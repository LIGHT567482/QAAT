package sync

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/qaat/attendance"
)

// studentRecord is one captured check-in in an offline session package. The
// U-Panel / migration 103+ fields are optional today: a hub that does not send
// them gets a lenient judgement (no geography, no per-student device claim), a
// hub with GPS gets the full geofence.
type studentRecord struct {
	LogID                 string  `json:"log_id"`
	SessionID             string  `json:"session_id"`
	StudentIDHash         string  `json:"student_id_hash"`
	DeviceFingerprintHash string  `json:"device_fingerprint_hash"`
	SequenceNumber        int     `json:"sequence_number"`
	CheckinTimestamp      string  `json:"checkin_timestamp"`
	EntryMethod           string  `json:"entry_method"`
	DeviceID              string  `json:"device_id"`
	SessionCode           string  `json:"session_code"`
	CapturedOffline       bool    `json:"captured_offline"`
	ReceivedAt            string  `json:"received_at"`
	Latitude              float64 `json:"latitude"`
	Longitude             float64 `json:"longitude"`
	GPSAccuracyMeters     float64 `json:"gps_accuracy_meters"`
}

// processStudentAttempts runs every captured record through the shared U-Panel
// attendance engine (github.com/qaat/attendance — the Go port of U-Panel's
// maybe_process_check_in, docs/U-PANEL-MIGRATION.md §4.2) before anything is
// written, then persists the verdict to the two tables that matter:
//
//   - checkin_attempts — EVERY attempt: accepted, duplicate, rejected, or still
//     awaiting its session (awaiting_session=true for the sweep job to retry),
//     with the reason and distance. A refused attempt is the evidence in the
//     commonest attendance dispute, so it is kept, not discarded.
//   - attendance_logs — only ACCEPTED attempts, as new ledger rows under the
//     entry_method the hub stamped (conventionally 'QR_SCAN', whose vector-clock
//     unique index uq_attendance_vector_clock still dedups re-uploads).
//
// The returned third counter is (a) records from sessions whose lecturer scan is
// still missing — kept from the pre-suspension relaxed gate so a student who
// attended still sees their record count — plus (b) records the engine REJECTED.
// It keeps the handler's legacy response field meaning.
func processStudentAttempts(
	ctx context.Context,
	conn *pgxpool.Conn,
	tenantID, coordinatorID string,
	records []studentRecord,
	hashToReg map[string]string,
	gatedSessions map[string]bool,
) (written, duplicates, rejected int, err error) {
	if len(records) == 0 {
		return 0, 0, 0, nil
	}
	now := time.Now().UTC()

	sessCache := map[string]*attendance.Session{}
	sessionsByCode := map[string]*attendance.Session{}

	lookup := attendance.Lookup{
		ByID: func(id string) *attendance.Session {
			if cached, ok := sessCache[id]; ok {
				return cached // nil is a valid cache entry for "not found"
			}
			s, lerr := loadSessionForVerifier(ctx, conn, tenantID, id)
			if lerr != nil || s == nil {
				sessCache[id] = nil
				return nil
			}
			sessCache[id] = s
			if s.Code != "" {
				sessionsByCode[s.Code] = s
			}
			return s
		},
		// Only ACTIVE sessions resolve a typed code (ux_sessions_active_code). A
		// claim typing a code the lecturer has not opened yet stays PENDING and
		// the sweep job retries it — it is never burnt as a rejection.
		ByCode: func(code string) *attendance.Session {
			if cached, ok := sessionsByCode[code]; ok {
				return cached
			}
			s, lerr := loadSessionByCodeForVerifier(ctx, conn, tenantID, code)
			if lerr != nil || s == nil {
				sessionsByCode[code] = nil
				return nil
			}
			sessionsByCode[code] = s
			sessCache[s.ID] = s
			return s
		},
	}

	for _, rec := range records {
		// Relaxed lecturer-scan gate telemetry, as before: RECORD everything, but
		// count records from sessions whose lecturer scan is still missing.
		if !gatedSessions[rec.SessionID] {
			rejected++
		}

		studentID := strings.TrimSpace(hashToReg[rec.StudentIDHash])
		if studentID == "" {
			// Fallback: a value that already fits the column is treated as a raw
			// reg-no (back-compat); a 64-hex hash is genuinely unresolved.
			if len(rec.StudentIDHash) <= 50 {
				studentID = strings.TrimSpace(rec.StudentIDHash)
			} else {
				rejected++
				continue
			}
		}
		if studentID == "" {
			continue
		}

		captured := attendance.ParseTimestamp(rec.CheckinTimestamp)
		// The ENGINE sees U-Panel's clientSubmittedAt (rec.ReceivedAt) for its
		// clock-skew rule — NOT server now. An offline hub genuinely captures
		// inside the window but uploads after the session closed; if server now
		// were the receipt time, the >5-minute drift rule would make it the
		// "effective" timestamp, already past end for a CLOSED session, and every
		// honest offline capture would be rejected. The client's receipt time can
		// only have been produced by the same clock family as its capture, so the
		// skew rule still deflects a forged capture. Server now is preserved in
		// received_at below, where migration 103 keeps it as the QA gap signal.
		attempt := attendance.Attempt{
			StudentID:          studentID,
			DeviceID:           rec.DeviceID,
			Latitude:           rec.Latitude,
			Longitude:          rec.Longitude,
			GPSAccuracyMeters:  rec.GPSAccuracyMeters,
			CapturedAt:         captured,
			ReceivedAt:         attendance.ParseTimestamp(rec.ReceivedAt),
			SessionID:          rec.SessionID,
			SessionCode:        rec.SessionCode,
			AwaitingSession:    rec.SessionID == "" && rec.SessionCode != "",
		}

		decision := attendance.Evaluate(attempt, lookup, attendance.Facts{
			Now: now,
			RecordExists: func(sessionID, reg string) bool {
				var exists bool
				if qerr := conn.QueryRow(ctx,
					`SELECT EXISTS(
						SELECT 1 FROM attendance_logs
						WHERE session_id = $1 AND student_id = $2
					)`, sessionID, reg).Scan(&exists); qerr != nil {
					return false // optimistic: the ledger's own dedup decides
				}
				return exists
			},
			// A hub is one shared station that many students legitimately type on:
			// the one-device-one-person rule governs per-student devices, never a
			// hub. Callers with real student phones pass a real DeviceID instead.
			DeviceUsedByOther: func(_, _, _ string) bool { return false },
		})

		sessionID := decision.SessionID
		if sessionID == "" {
			sessionID = rec.SessionID
		}

		switch decision.Verdict {
		case attendance.VerdictPending:
			if cerr := upsertAttempt(ctx, conn, tenantID, rec, sessionID, studentID,
				decision, "PENDING", true, now, captured); cerr != nil {
				return written, duplicates, rejected, cerr
			}
			continue

		case attendance.VerdictRejected:
			if cerr := upsertAttempt(ctx, conn, tenantID, rec, sessionID, studentID,
				decision, "REJECTED", false, now, captured); cerr != nil {
				return written, duplicates, rejected, cerr
			}
			rejected++
			continue
		}

		// ACCEPTED or DUPLICATE: stamp the attempt row first so the verdict has an
		// audit trail even if the ledger write below races with another upload.
		outcome := "PRESENT"
		if decision.Verdict == attendance.VerdictDuplicate {
			outcome = "DUPLICATE"
		}
		if cerr := upsertAttempt(ctx, conn, tenantID, rec, sessionID, studentID,
			decision, outcome, false, now, captured); cerr != nil {
			return written, duplicates, rejected, cerr
		}

		if decision.Verdict == attendance.VerdictDuplicate {
			duplicates++
			continue
		}

		entryMethod := strings.TrimSpace(rec.EntryMethod)
		if entryMethod == "" {
			entryMethod = "QR_SCAN" // the hub's normal check-in label (see AGENTS.md)
		}
		var wroteLogID string
		qerr := conn.QueryRow(ctx, `
			INSERT INTO attendance_logs
			  (log_id, tenant_id, session_id, student_id, checkin_timestamp,
			   captured_at, received_at, captured_offline, client_queue_id,
			   device_fingerprint_hash, device_id, latitude, longitude, distance_meters,
			   sequence_number, entry_method, coordinator_id)
			VALUES ($1,$2,$3,$4,COALESCE($5::timestamptz,$6::timestamptz),
			        $5::timestamptz,$6::timestamptz,$7::boolean,$8,
			        $9,$10,
			        $11::double precision,$12::double precision,$13::integer,
			        $14,$15::entry_method_enum,$16)
			ON CONFLICT DO NOTHING
			RETURNING log_id`,
			rec.LogID, tenantID, sessionID, studentID, captured, now,
			rec.CapturedOffline, rec.LogID,
			nullable(rec.DeviceFingerprintHash), nullable(rec.DeviceID),
			nullableFloat(rec.Latitude), nullableFloat(rec.Longitude),
			nullableInt(decision.DistanceMeters),
			rec.SequenceNumber, entryMethod, coordinatorID,
		).Scan(&wroteLogID)
		if errors.Is(qerr, pgx.ErrNoRows) {
			// ON CONFLICT DO NOTHING swallowed the row: a genuine re-upload of the
			// same log_id / vector-clock key. Count it, don't double-write.
			duplicates++
			continue
		}
		if qerr != nil {
			return written, duplicates, rejected, fmt.Errorf("insert log %s: %w", rec.LogID, qerr)
		}
		written++
	}
	return written, duplicates, rejected, nil
}

// upsertAttempt records one verdict on checkin_attempts, keyed by the hub's own
// log_id so a flaky re-upload re-marks the same attempt instead of creating a
// second one. The session_id stays NULL for attempts that matched nothing, which
// is exactly the kept attempt that proves "nobody could get in".
func upsertAttempt(
	ctx context.Context,
	conn *pgxpool.Conn,
	tenantID string,
	rec studentRecord,
	sessionID, studentID string,
	decision attendance.Decision,
	outcome string,
	awaiting bool,
	now time.Time,
	captured *time.Time,
) error {
	_, qerr := conn.Exec(ctx, `
		INSERT INTO checkin_attempts
		  (attempt_id, tenant_id, session_id, student_id, session_code, outcome,
		   reason, latitude, longitude, distance_meters, device_id, captured_offline,
		   attempted_at, received_at, awaiting_session, list_id, resolved_at)
		VALUES ($1,$2,NULLIF($3,'')::uuid,
		        $4,$5,$6,$7,
		        $8::double precision,$9::double precision,$10::integer,$11,
		        $12::boolean,
		        COALESCE($13::timestamptz,$14::timestamptz),$14::timestamptz,
		        $15::boolean,
		        NULLIF($16,'')::uuid,
		        CASE WHEN NOT $15::boolean THEN now() ELSE NULL END)
		ON CONFLICT (attempt_id)
		DO UPDATE SET outcome = EXCLUDED.outcome,
		              reason = CASE WHEN EXCLUDED.reason <> ''
		                            THEN EXCLUDED.reason ELSE checkin_attempts.reason END,
		              session_id = COALESCE(NULLIF(EXCLUDED.session_id::text,'')::uuid, checkin_attempts.session_id),
		              list_id   = COALESCE(NULLIF(EXCLUDED.list_id::text,'')::uuid, checkin_attempts.list_id),
		              awaiting_session = EXCLUDED.awaiting_session,
		              resolved_at = COALESCE(checkin_attempts.resolved_at, EXCLUDED.resolved_at),
		              distance_meters = COALESCE(EXCLUDED.distance_meters, checkin_attempts.distance_meters)`,
		rec.LogID, tenantID, sessionID, studentID, rec.SessionCode, outcome,
		decision.Reason, nullableFloat(rec.Latitude), nullableFloat(rec.Longitude),
		nullableInt(decision.DistanceMeters), nullable(rec.DeviceID),
		rec.CapturedOffline, captured, now, awaiting, decision.ListID,
	)
	return qerr
}

func loadSessionForVerifier(ctx context.Context, conn *pgxpool.Conn, tenantID, id string) (*attendance.Session, error) {
	var (
		s            attendance.Session
		listID, code sql.NullString
		status       string
		start, end   sql.NullTime
		lat, lon     sql.NullFloat64
		radius       int
		acc          sql.NullInt64
	)
	err := conn.QueryRow(ctx, `
		SELECT session_id::text, list_id::text, session_code,
		       session_status::text, checkin_window_start, checkin_window_end,
		       latitude, longitude, radius_meters, gps_accuracy_meters
		FROM sessions WHERE tenant_id = $1 AND session_id = $2`,
		tenantID, id).Scan(
		&s.ID, &listID, &code, &status, &start, &end, &lat, &lon, &radius, &acc)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	s.ID = id
	s.ListID = listID.String
	s.Code = code.String
	s.Status = status
	if start.Valid {
		t := start.Time
		s.Start = &t
	}
	if end.Valid {
		t := end.Time
		s.End = &t
	}
	s.Latitude = lat.Float64
	s.Longitude = lon.Float64
	s.RadiusMeters = radius
	if acc.Valid {
		s.GPSAccuracyMeters = float64(acc.Int64)
	}
	// A hub that opened a session without a fix cannot be geofenced; rejecting a
	// whole hall for a weak signal would turn it into a hall of absences. U-Panel
	// answers locationMetadataPending — same intent, different cause.
	if s.Latitude == 0 && s.Longitude == 0 {
		s.LocationMetadataPending = true
	}
	return &s, nil
}

func loadSessionByCodeForVerifier(ctx context.Context, conn *pgxpool.Conn, tenantID, code string) (*attendance.Session, error) {
	var id sql.NullString
	err := conn.QueryRow(ctx, `
		SELECT session_id::text FROM sessions
		WHERE tenant_id = $1 AND upper(session_code) = upper($2)
		  AND session_status = 'ACTIVE'
		ORDER BY created_at DESC LIMIT 1`, tenantID, code).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return loadSessionForVerifier(ctx, conn, tenantID, id.String)
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func nullableFloat(f float64) *float64 {
	if f == 0 {
		return nil
	}
	return &f
}

func nullableInt(v int) *int {
	return &v
}