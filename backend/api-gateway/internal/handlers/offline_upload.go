package handlers

// ── STUDENT MODULE: DEFERRED TO V2 ───────────────────────────────────────────────────────────
//
// Nothing in this file is reachable in v1. KIU QAAT ships as an internal Quality Assurance
// system, and every route that reached these handlers is commented out in
// internal/router/router.go. The code is retained, not deleted: it still compiles and its tests
// still run, so restoring the module is uncommenting its routes rather than rewriting it.

// DRAINING THE PHONE'S QUEUE.
//
// The app tries the server first. When it cannot reach it, the check-in is written to a local queue
// on the device and this endpoint receives the backlog once there is a connection again.
//
// EVERY RECORD ARRIVING HERE IS A CLAIM, NOT AN OBSERVATION. Live check-ins are witnessed: the
// server sees the request while the lecture is happening and stamps the time itself. A queued one
// is the device saying, later, that something happened earlier — with a timestamp from a clock its
// owner can set and coordinates it chose to report. That does not make it false; a lecture in a
// basement is exactly the case this exists for. It makes it EVIDENCE OF A DIFFERENT KIND, and the
// rows are marked so that whoever reads the register can tell which they are looking at.
//
// So each row keeps the phone's claimed time AND the server's receipt time, and is flagged as
// captured offline. A QA monitor reconciling a disputed lecture can then see that forty students
// uploaded five minutes after the lecture ended, or that one uploaded three days later — and ask
// about the second without having to doubt the first.
//
// The geofence is still applied, against the coordinates the phone recorded at capture time. A
// queued record from outside the radius is rejected exactly as a live one would be: being offline
// is a reason to defer the upload, not a reason to relax the rule.

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/checkin"
)

// POST /api/v1/attendance/offline-batch
//
// Body: {items: [{queue_id, session_code, student_id, latitude, longitude, device_id, captured_at}]}
//
// Answers per item rather than failing the batch: a phone holding thirty queued check-ins, one of
// which is for a register that has since been deleted, must be able to upload the other twenty-nine
// and clear them from its queue. An all-or-nothing response would leave it retrying the same bad
// item forever and never delivering the good ones.
func OfflineBatchUpload(pool *pgxpool.Pool) http.HandlerFunc {
	type item struct {
		QueueID     string   `json:"queue_id"`
		SessionCode string   `json:"session_code"`
		StudentID   string   `json:"student_id"`
		Latitude    *float64 `json:"latitude"`
		Longitude   *float64 `json:"longitude"`
		DeviceID    string   `json:"device_id"`
		CapturedAt  string   `json:"captured_at"`
	}
	type result struct {
		QueueID  string `json:"queue_id"`
		Status   string `json:"status"` // STORED | DUPLICATE | REJECTED
		Message  string `json:"message,omitempty"`
		Distance int    `json:"distance_meters,omitempty"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Items []item `json:"items"`
		}
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed batch"))
			return
		}
		if len(req.Items) == 0 {
			writeJSON(w, http.StatusOK, map[string]interface{}{"results": []result{}, "stored": 0})
			return
		}
		// A phone that has been offline for a week still uploads in one go, but an unbounded batch
		// is a way to tie up the gateway. Anything larger is a client bug or an attack.
		if len(req.Items) > 500 {
			writeJSON(w, http.StatusRequestEntityTooLarge, errBody("BATCH_TOO_LARGE",
				"upload at most 500 queued check-ins at a time"))
			return
		}

		now := time.Now().UTC()
		out := make([]result, 0, len(req.Items))
		stored := 0

		for _, it := range req.Items {
			qid := strings.TrimSpace(it.QueueID)
			code := checkin.NormaliseSessionCode(it.SessionCode)
			student := strings.TrimSpace(it.StudentID)
			if qid == "" || code == "" || student == "" {
				out = append(out, result{QueueID: qid, Status: "REJECTED",
					Message: "queue_id, session_code and student_id are all required"})
				continue
			}

			// The session need NOT still be ACTIVE. A queued record is by definition late, and the
			// register it belongs to has usually closed by the time a signal returns — refusing on
			// that basis would throw away every record this endpoint exists to collect.
			var (
				sessionID, tenantID string
				lat, lon            *float64
				radius              int
				winStart, winEnd    *time.Time
			)
			err := pool.QueryRow(r.Context(), `
				SELECT session_id::text, tenant_id::text, latitude, longitude,
				       COALESCE(radius_meters, $2), checkin_window_start, checkin_window_end
				  FROM sessions WHERE upper(session_code) = $1
				 ORDER BY created_at DESC LIMIT 1`, code, checkin.DefaultRadiusMeters).
				Scan(&sessionID, &tenantID, &lat, &lon, &radius, &winStart, &winEnd)
			if errors.Is(err, pgx.ErrNoRows) {
				logAttempt(r.Context(), pool, attempt{StudentID: student, Code: code,
					Outcome: "REJECTED", Reason: "no register with that code",
					Lat: it.Latitude, Lon: it.Longitude, DeviceID: it.DeviceID, Offline: true})
				out = append(out, result{QueueID: qid, Status: "REJECTED",
					Message: "no register was ever opened with that code"})
				continue
			}
			if err != nil {
				out = append(out, result{QueueID: qid, Status: "REJECTED", Message: "could not be processed"})
				continue
			}

			// Judged at the moment of CAPTURE, not of upload: the student was where they were when
			// they tapped, and the window they must fall inside is the one that was open then.
			captured := now
			if t, perr := time.Parse(time.RFC3339, strings.TrimSpace(it.CapturedAt)); perr == nil {
				captured = t.UTC()
			}

			geo := checkin.SessionGeo{RadiusMeters: radius, HasLocation: lat != nil && lon != nil}
			if geo.HasLocation {
				geo.Lat, geo.Lon = *lat, *lon
			}
			if winStart != nil {
				geo.Start = *winStart
			}
			if winEnd != nil {
				geo.End = *winEnd
			}
			sLat, sLon := 0.0, 0.0
			if it.Latitude != nil {
				sLat = *it.Latitude
			}
			if it.Longitude != nil {
				sLon = *it.Longitude
			}

			v := checkin.VerifyCheckin(geo, sLat, sLon, captured)
			if !v.OK {
				logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
					StudentID: student, Code: code, Outcome: "REJECTED", Reason: v.Reason,
					Lat: it.Latitude, Lon: it.Longitude, Distance: v.Distance,
					DeviceID: it.DeviceID, Offline: true, At: captured})
				out = append(out, result{QueueID: qid, Status: "REJECTED",
					Message: v.Reason, Distance: v.Distance})
				continue
			}

			// Two ways the same attendance can arrive twice: the student is already present (they
			// also checked in live), or this exact queued item was uploaded before and the
			// response was lost. Both are DUPLICATE, and both mean the phone should stop retrying.
			var logID string
			err = pool.QueryRow(r.Context(), `
				INSERT INTO attendance_logs (
					tenant_id, session_id, student_id, checkin_timestamp, sequence_number,
					entry_method, latitude, longitude, distance_meters, device_id,
					captured_at, received_at, captured_offline, client_queue_id
				)
				SELECT $1::uuid, $2::uuid, $3::text, $8, 
				       COALESCE((SELECT MAX(sequence_number) + 1 FROM attendance_logs WHERE session_id = $2::uuid), 1),
				       'AUTHENTICATED', $4, $5, $6, NULLIF($7,''), $8, $9, true, $10
				 WHERE NOT EXISTS (
				       SELECT 1 FROM attendance_logs
				        WHERE session_id = $2::uuid AND btrim(lower(student_id)) = btrim(lower($3::text)))
				   AND NOT EXISTS (
				       SELECT 1 FROM attendance_logs WHERE client_queue_id = $10)
				RETURNING log_id::text`,
				tenantID, sessionID, student, it.Latitude, it.Longitude, v.Distance, it.DeviceID,
				captured, now, qid).Scan(&logID)
			if errors.Is(err, pgx.ErrNoRows) {
				logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
					StudentID: student, Code: code, Outcome: "DUPLICATE", Reason: "already recorded",
					Lat: it.Latitude, Lon: it.Longitude, Distance: v.Distance,
					DeviceID: it.DeviceID, Offline: true, At: captured})
				out = append(out, result{QueueID: qid, Status: "DUPLICATE",
					Message: "already recorded — you can clear this from the queue"})
				continue
			}
			if err != nil {
				out = append(out, result{QueueID: qid, Status: "REJECTED", Message: "could not be stored"})
				continue
			}
			logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
				StudentID: student, Code: code, Outcome: "PRESENT",
				Lat: it.Latitude, Lon: it.Longitude, Distance: v.Distance,
				DeviceID: it.DeviceID, Offline: true, At: captured})
			stored++
			out = append(out, result{QueueID: qid, Status: "STORED", Distance: v.Distance})
		}

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"results": out, "stored": stored, "received": len(req.Items),
			"server_time": now.Format(time.RFC3339),
		})
	}
}

// GET /api/v1/attendance/ping
//
// What the app calls to decide whether it can reach the server at all. Deliberately trivial and
// unauthenticated: the question is "is there a route to the gateway", and requiring a token would
// conflate "no network" with "my session expired" — two problems with completely different
// remedies, which the app must not confuse when deciding whether to queue.
//
// Returns the server clock so a device with a wrong clock can be spotted at capture time rather
// than argued about weeks later when its queued rows look impossible.
func AttendancePing() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"ok":          true,
			"server_time": time.Now().UTC().Format(time.RFC3339),
		})
	}
}
