package jobs

// Session-lifecycle sweeps — the Go port of U-Panel's Celery beats
// (docs/U-PANEL-MIGRATION.md §4.3), running in-process on the scheduler.
//
//   - awaiting_session_claims: a check-in a student made against a code whose register was
//     not open yet is kept as checkin_attempts.awaiting_session=true (the sync-receiver's
//     VerdictPending path) and retried here once a lecturer opens a register with that code.
//     The rejudgement runs through the SAME shared verifier (github.com/qaat/attendance) as
//     a live hub check-in, so an offline class that typed before the register opened gets
//     exactly the verdict they would have got live: PRESENT (a new ledger row), DUPLICATE or
//     REJECTED. A claim the sweep still cannot link — and one older than U-Panel's 7-day
//     queue retention — is closed so the queue cannot grow without bound.
//   - finalize_expired_sessions: the backstop that ends a session nobody closed. A register
//     (list-backed) past its checkin_window_end and a coordinator session past its
//     auto_close_time (T+auto_kill_minutes per tenant) are locked as AUTO_CLOSED at the
//     moment they became stale, and already-ended sessions that were never flagged
//     `finalized` finally are. The last pass fills the lecturer-attendance hours any closing
//     path skipped.
//
// Both are idempotent and safe to replay: the awaiting flag gates the claim side, status +
// finalized gate the expiry side, and the contact-hours guard (lecturer_ended_at) governs
// the gap-fill — a replayed window changes nothing.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
	"github.com/qaat/api-gateway/internal/scheduler"
	"github.com/qaat/attendance"
)

const (
	// awaitingBatchSize caps one awaiting-sweep scan so a long outage replays a bounded
	// queue; rows past the cap are taken by the next sweep.
	awaitingBatchSize = 200
	// expiryBatchSize caps one expiry sweep in the same spirit.
	expiryBatchSize = 500
	// awaitingRetention mirrors U-Panel's 7-day offline-queue retention: a claim the sweep
	// still cannot link after a week is closed as REJECTED rather than retried forever.
	awaitingRetention = 7 * 24 * time.Hour
)

// RegisterSessionSweeps wires the two session-lifecycle sweeps into the scheduler.
//
// The awaiting sweep needs BOTH pools: it reads the pending queue across every tenant on the
// admin pool, but writes the verdict through a connection pinned to the attempt's tenant —
// attendance_logs INSERTs are RLS-gated (WITH CHECK tenant match) and cannot go through the
// BYPASSRLS admin pool. The expiry sweep closes sessions under every tenant that has one,
// which is exactly the cross-tenant platform role the admin pool exists for.
func RegisterSessionSweeps(s *scheduler.Scheduler, pool, adminPool *pgxpool.Pool) {
	s.Register(scheduler.Job{
		Name: "awaiting_session_claims", Every: minute, MaxCatchUp: 30 * minute,
		Run: func(ctx context.Context, w scheduler.Window) error {
			return resolveAwaitingSessionClaims(ctx, pool, adminPool)
		},
	})
	s.Register(scheduler.Job{
		Name: "finalize_expired_sessions", Every: minute, MaxCatchUp: 30 * minute,
		Run: func(ctx context.Context, w scheduler.Window) error {
			return finalizeExpiredSessions(ctx, adminPool)
		},
	})
}

// pendingClaim is one unresolved check-in the awaiting sweep is retrying.
type pendingClaim struct {
	tenantID        string
	attemptID       string
	studentID       string
	code            string
	listID          string
	latitude        sql.NullFloat64
	longitude       sql.NullFloat64
	deviceID        string
	capturedOffline bool
	attemptedAt     time.Time
	receivedAt      time.Time
}

// resolveAwaitingSessionClaims rescan the awaiting queue and judges each claim again into a
// register that may have opened since the last sweep. Both the read and the per-tenant
// processing are batch-bounded; the queue is drained across successive windows.
func resolveAwaitingSessionClaims(ctx context.Context, pool, adminPool *pgxpool.Pool) error {
	rows, err := adminPool.Query(ctx, `
		SELECT attempt_id::text, tenant_id::text,
		       student_id, session_code,
		       COALESCE(list_id::text, ''),
		       latitude, longitude, COALESCE(device_id, ''),
		       captured_offline, attempted_at, received_at
		  FROM checkin_attempts
		 WHERE awaiting_session = true
		 ORDER BY attempted_at
		 LIMIT $1`, awaitingBatchSize)
	if err != nil {
		return fmt.Errorf("awaiting claims: %w", err)
	}
	defer rows.Close()

	var (
		batch   []pendingClaim
		tenants []string
		seen    = map[string]bool{}
	)
	for rows.Next() {
		var p pendingClaim
		var deviceID sql.NullString
		if err := rows.Scan(&p.attemptID, &p.tenantID, &p.studentID, &p.code,
			&p.listID, &p.latitude, &p.longitude, &deviceID,
			&p.capturedOffline, &p.attemptedAt, &p.receivedAt); err != nil {
			return fmt.Errorf("scan awaiting claim: %w", err)
		}
		p.deviceID = deviceID.String
		batch = append(batch, p)
		if !seen[p.tenantID] {
			seen[p.tenantID] = true
			tenants = append(tenants, p.tenantID)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("awaiting claims: %w", err)
	}

	now := time.Now().UTC()
	for _, tenantID := range tenants {
		conn, err := pool.Acquire(ctx)
		if err != nil {
			return fmt.Errorf("acquire tenant conn: %w", err)
		}
		if err := middleware.SetTenantConn(ctx, conn, tenantID); err != nil {
			conn.Release()
			return fmt.Errorf("pin tenant %s: %w", tenantID, err)
		}
		for _, p := range batch {
			if p.tenantID != tenantID {
				continue
			}
			if err := resolveOneAwaiting(ctx, conn, p, now); err != nil {
				conn.Release()
				return err
			}
		}
		conn.Release()
	}
	return nil
}

// resolveOneAwaiting judges one queued claim through the shared verifier and persists the
// verdict on checkin_attempts. A claim the sweep still cannot link keeps awaiting_session
// for the next sweep; only a resolution — or the retention horizon — clears the flag.
func resolveOneAwaiting(ctx context.Context, conn *pgxpool.Conn, p pendingClaim, now time.Time) error {
	captured := p.attemptedAt
	received := p.attemptedAt
	if !p.capturedOffline {
		// A live-path queue (rare) records the server receipt separately. For an offline hub
		// the client's own receipt is the engine's clock-skew anchor, exactly as the
		// sync-receiver judged it before queueing.
		received = p.receivedAt
	}

	var resolved *sweepSession
	decision := attendance.Evaluate(
		attendance.Attempt{
			StudentID:       p.studentID,
			DeviceID:        p.deviceID,
			Latitude:        p.latitude.Float64,
			Longitude:       p.longitude.Float64,
			CapturedAt:      &captured,
			ReceivedAt:      &received,
			SessionCode:     p.code,
			AwaitingSession: true,
		},
		attendance.Lookup{
			ByCode: func(code string) *attendance.Session {
				s := loadSweepSessionByCode(ctx, conn, p.tenantID, code)
				if s == nil {
					return nil
				}
				resolved = s
				return &s.Session
			},
		},
		attendance.Facts{
			Now: now,
			RecordExists: func(sessionID, reg string) bool {
				var exists bool
				if qerr := conn.QueryRow(ctx,
					`SELECT EXISTS(SELECT 1 FROM attendance_logs
					   WHERE session_id = $1::uuid AND student_id = $2)`,
					sessionID, reg).Scan(&exists); qerr != nil {
					return false // optimistic: the ledger's own dedup decides at insert
				}
				return exists
			},
			// A hub is one shared station students queue at; the one-device-one-person rule
			// governs per-student phones and is deliberately off here, as on the live path.
			DeviceUsedByOther: func(_, _, _ string) bool { return false },
		},
	)

	if decision.Verdict == attendance.VerdictPending {
		// The register still is not open under this code. A claim older than the retention
		// horizon is closed rather than retried forever.
		if now.Sub(captured) > awaitingRetention {
			return finalizeAttempt(ctx, conn, p, attendance.Decision{
				Verdict: attendance.VerdictRejected,
				Reason:  "no register opened for this code within retention",
			}, "REJECTED")
		}
		return nil
	}

	outcome := "PRESENT"
	switch decision.Verdict {
	case attendance.VerdictDuplicate:
		outcome = "DUPLICATE"
	case attendance.VerdictRejected:
		outcome = "REJECTED"
	}

	// ACCEPTED: the ledger row is the point, so write it while the attempt is still queued.
	// RecordExists already proved absence; ON CONFLICT DO NOTHING catches a racing hub write,
	// and either way the attempt is marked PRESENT.
	if decision.Verdict == attendance.VerdictAccepted && resolved != nil {
		var logID string
		qerr := conn.QueryRow(ctx, `
			INSERT INTO attendance_logs
			  (tenant_id, session_id, student_id, checkin_timestamp,
			   captured_at, received_at, captured_offline, entry_method,
			   device_id, latitude, longitude, distance_meters,
			   sequence_number, coordinator_id)
			VALUES ($1, $2::uuid, $3,
			        $4::timestamptz, $4::timestamptz, $5::timestamptz,
			        $6::boolean, $7::entry_method_enum,
			        NULLIF($8, ''), $9::double precision, $10::double precision, $11::integer,
			        (SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM attendance_logs
			          WHERE session_id = $2::uuid),
			        NULLIF($12, ''))
			ON CONFLICT DO NOTHING
			RETURNING log_id::text`,
			p.tenantID, decision.SessionID, strings.TrimSpace(p.studentID),
			captured, now, p.capturedOffline, "QR_SCAN",
			p.deviceID, nullableFloatSweep(p.latitude.Float64), nullableFloatSweep(p.longitude.Float64),
			decision.DistanceMeters, resolved.coordinatorID).Scan(&logID)
		if qerr != nil && !errors.Is(qerr, pgx.ErrNoRows) {
			return fmt.Errorf("resolve %s: write ledger: %w", p.attemptID, qerr)
		}
	}

	return finalizeAttempt(ctx, conn, p, decision, outcome)
}

// finalizeAttempt closes one queued claim: records the verdict the verifier reached and
// clears the awaiting flag, stamping resolved_at. Only rows still awaiting are touched, so a
// replayed window cannot re-resolve a claim the previous run closed.
func finalizeAttempt(ctx context.Context, conn *pgxpool.Conn, p pendingClaim, decision attendance.Decision, outcome string) error {
	if _, err := conn.Exec(ctx, `
		UPDATE checkin_attempts
		   SET outcome = $1,
		       reason = CASE WHEN $2 <> '' THEN $2 ELSE reason END,
		       session_id = COALESCE(NULLIF($3, '')::uuid, session_id),
		       list_id = COALESCE(NULLIF($4, '')::uuid, list_id),
		       distance_meters = COALESCE($5, distance_meters),
		       awaiting_session = false,
		       resolved_at = now()
		 WHERE attempt_id = $6::uuid AND awaiting_session = true`,
		outcome, decision.Reason, decision.SessionID, decision.ListID,
		intOrNullSweep(decision.DistanceMeters), p.attemptID); err != nil {
		return fmt.Errorf("resolve %s: finalize attempt: %w", p.attemptID, err)
	}
	return nil
}

// sweepSession is a verifier session plus the two facts the sweep's own writes need: the
// tenant it belongs to and its coordinator_id (half the vector-clock key on the ledger row).
type sweepSession struct {
	attendance.Session
	tenantID      string
	coordinatorID string
}

// loadSweepSessionByCode resolves a spoken code to an ACTIVE register, tenant-scoped. Only an
// ACTIVE session can take the queued claim (ux_sessions_active_code); a code whose register
// closed in the meantime stays unresolved and the claim is judged by the engine accordingly.
func loadSweepSessionByCode(ctx context.Context, conn *pgxpool.Conn, tenantID, norm string) *sweepSession {
	var id sql.NullString
	err := conn.QueryRow(ctx, `
		SELECT session_id::text FROM sessions
		 WHERE tenant_id = $1::uuid AND upper(session_code) = upper($2)
		   AND session_status = 'ACTIVE'
		 ORDER BY created_at DESC LIMIT 1`,
		tenantID, attendance.NormaliseCode(norm)).Scan(&id)
	if err != nil || !id.Valid {
		return nil
	}
	return loadSweepSession(ctx, conn, tenantID, id.String)
}

// loadSweepSession loads one session with the same columns and rules as the live verifier's
// loaders (loadHubSession / loadSessionForVerifier), so the sweep and the live path answer
// identically for the same session.
func loadSweepSession(ctx context.Context, conn *pgxpool.Conn, tenantID, id string) *sweepSession {
	var (
		s            sweepSession
		listID, code sql.NullString
		status       string
		start, end   sql.NullTime
		lat, lon     sql.NullFloat64
		radius       int
		acc          sql.NullInt64
		coordID      sql.NullString
	)
	err := conn.QueryRow(ctx, `
		SELECT session_id::text, list_id::text, session_code,
		       session_status::text, checkin_window_start, checkin_window_end,
		       latitude, longitude, radius_meters, gps_accuracy_meters,
		       coordinator_id
		  FROM sessions
		 WHERE tenant_id = $1::uuid AND session_id = $2::uuid`,
		tenantID, id).Scan(&s.ID, &listID, &code, &status, &start, &end,
		&lat, &lon, &radius, &acc, &coordID)
	if err != nil {
		return nil
	}
	s.tenantID = tenantID
	s.coordinatorID = coordID.String
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
	// A register opened without a fix cannot be geofenced; accepting on the code and window is
	// honest (weak signal is not absence), matching the engine's LocationMetadataPending.
	if s.Latitude == 0 && s.Longitude == 0 {
		s.LocationMetadataPending = true
	}
	return &s
}

// finalizeExpiredSessions is the server-side backstop. Two records witness a lecture — the
// coordinator's session and the QA patrol — and a session ends in one of two ways:
//
//   - it was already ended (CLOSED by the closing handler or AUTO_CLOSED by the coordinator's
//     PWA) but never flagged `finalized` — the ledger is finalised here;
//   - it is still ACTIVE past its window — a register (list-backed) past its
//     checkin_window_end, or a coordinator session past its auto_close_time (T+180 by
//     default, derived per tenant). It is locked as AUTO_CLOSED at the moment it became
//     stale, so the contact hours booked are the hours actually taught.
//
// The last pass fills the lecturer-attendance gap any closing path left, so every finalised
// session carries its contact_hours row whichever path ended it.
func finalizeExpiredSessions(ctx context.Context, adminPool *pgxpool.Pool) error {
	// Sessions already ended but never finalised.
	if _, err := adminPool.Exec(ctx, `
		UPDATE sessions s SET finalized = true
		 WHERE s.session_id IN (
		     SELECT session_id FROM sessions
		      WHERE finalized = false AND session_status IN ('CLOSED', 'AUTO_CLOSED')
		      ORDER BY session_id LIMIT $1)`, expiryBatchSize); err != nil {
		return fmt.Errorf("finalize ended sessions: %w", err)
	}

	// ACTIVE sessions whose window has run out. The close time is the moment the class was
	// supposed to stop — a register's checkin_window_end, a coordinator session's
	// auto_close_time, or T+auto_kill_minutes from the open when no timetable slot set one.
	if _, err := adminPool.Exec(ctx, `
		WITH victims AS (
		    SELECT s.session_id,
		           CASE WHEN s.list_id IS NOT NULL THEN s.checkin_window_end
		                ELSE COALESCE(s.auto_close_time,
		                              s.gate_open_time + make_interval(mins => t.auto_kill_minutes))
		           END AS close_at
		      FROM sessions s
		      JOIN tenants t ON t.tenant_id = s.tenant_id
		     WHERE s.finalized = false
		       AND s.session_status = 'ACTIVE'
		       AND s.gate_open_time IS NOT NULL
		       AND (
		             (s.list_id IS NOT NULL AND s.checkin_window_end IS NOT NULL
		              AND s.checkin_window_end < now())
		             OR (s.list_id IS NULL AND s.auto_close_time IS NOT NULL
		                 AND s.auto_close_time < now())
		             OR (s.list_id IS NULL AND s.auto_close_time IS NULL
		                 AND s.gate_open_time + make_interval(mins => t.auto_kill_minutes) < now())
		       )
		     ORDER BY s.session_id
		     LIMIT $1
		)
		UPDATE sessions s
		   SET session_status = 'AUTO_CLOSED',
		       gate_close_time = v.close_at,
		       coordinator_end_time = v.close_at,
		       finalized = true
		  FROM victims v
		 WHERE s.session_id = v.session_id`, expiryBatchSize); err != nil {
		return fmt.Errorf("expire ACTIVE sessions: %w", err)
	}

	// Any finalised session whose lecturer-attendance row is still open gets its hours booked
	// from the gate times. Idempotent: lecturer_ended_at is the guard.
	if _, err := adminPool.Exec(ctx, `
		UPDATE lecturer_attendance_logs lal
		   SET gate_close_time = s.gate_close_time,
		       lecturer_ended_at = s.gate_close_time,
		       contact_hours = ROUND(EXTRACT(EPOCH FROM (s.gate_close_time - lal.gate_open_time)) / 3600.0, 2)
		  FROM sessions s
		 WHERE lal.session_id = s.session_id
		   AND lal.lecturer_ended_at IS NULL
		   AND s.finalized = true
		   AND s.session_status IN ('CLOSED', 'AUTO_CLOSED')
		   AND s.gate_close_time IS NOT NULL
		   AND s.gate_close_time > lal.gate_open_time`); err != nil {
		return fmt.Errorf("book lecturer hours: %w", err)
	}
	return nil
}

func nullableFloatSweep(f float64) *float64 {
	if f == 0 {
		return nil
	}
	return &f
}

func intOrNullSweep(v int) *int {
	if v == 0 {
		return nil
	}
	return &v
}
