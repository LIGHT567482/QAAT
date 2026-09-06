package handlers

// ── STUDENT MODULE: DEFERRED TO V2 ───────────────────────────────────────────────────────────
//
// Nothing in this file is reachable in v1. KIU QAAT ships as an internal Quality Assurance
// system, and every route that reached these handlers is commented out in
// internal/router/router.go. The code is retained, not deleted: it still compiles and its tests
// still run, so restoring the module is uncommenting its routes rather than rewriting it.

// ATTENDANCE THE WAY U-PANEL TAKES IT: a spoken code, a circle, a window.
//
// The lecturer opens the register and reads out a four-character code. Students type it, their
// phones send their own coordinates, and the check-in is accepted when the code is live and the
// phone is inside the session's circle. This mirrors U-Panel's list -> session -> record sequence
// so a QAAT session and a U-Panel session describe the same event in the same fields.
//
// QA MONITOR ATTENDANCE IS NOT TOUCHED. The patrol round writes to lecturer_patrol_logs through its
// own path and is the institution's only INDEPENDENT witness that teaching happened — a monitor
// walks in and sees a lecture with their own eyes. Routing that through a self-reported coordinate
// would make the independent record depend on the same phone-supplied evidence it exists to check.
//
// The hotspot path is left intact beside this one. It is what works in a hall with no signal, and
// this endpoint cannot run there at all: it needs the student's phone to reach the gateway.

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/checkin"
	"github.com/qaat/api-gateway/internal/middleware"
)

// POST /api/v1/sessions/{session_id}/open-geo
//
// Gives a session a code and remembers where it was opened. Returns the code for the lecturer to
// read out. Re-opening returns the SAME code rather than minting a new one: a lecturer who reloads
// the page mid-lecture must not invalidate the number forty students have already written down.
func OpenGeoSession(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := strings.TrimSpace(chi.URLParam(r, "session_id"))
		if !middleware.ValidTenantID(sessionID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "a valid session id is required"))
			return
		}
		var req struct {
			Latitude  *float64 `json:"latitude"`
			Longitude *float64 `json:"longitude"`
			Accuracy  *int     `json:"accuracy_meters"`
			Radius    *int     `json:"radius_meters"`
			Minutes   *int     `json:"open_minutes"`
		}
		_ = decodeJSON(r, &req)

		radius := checkin.DefaultRadiusMeters
		if req.Radius != nil && *req.Radius > 0 {
			radius = *req.Radius
		}
		// U-Panel's observed window was fifteen minutes. Long enough to register a hall, short
		// enough that a code overheard in the corridor is worthless by the time it is used.
		minutes := 15
		if req.Minutes != nil && *req.Minutes > 0 && *req.Minutes <= 240 {
			minutes = *req.Minutes
		}

		var existing *string
		err := pool.QueryRow(r.Context(),
			`SELECT session_code FROM sessions WHERE session_id = $1`, sessionID).Scan(&existing)
		if errors.Is(err, pgx.ErrNoRows) {
			writeJSON(w, http.StatusNotFound, errBody("SESSION_NOT_FOUND", "no such session"))
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		code := ""
		if existing != nil {
			code = strings.TrimSpace(*existing)
		}
		if code == "" {
			// Retry on collision: the unique index covers only ACTIVE sessions, so a clash is
			// possible and is a normal race, not an error to hand back to a lecturer.
			for attempt := 0; attempt < 8 && code == ""; attempt++ {
				c, gErr := checkin.NewSessionCode(4)
				if gErr != nil {
					writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not generate a code"))
					return
				}
				var taken bool
				if pool.QueryRow(r.Context(),
					`SELECT EXISTS (SELECT 1 FROM sessions
					   WHERE upper(session_code) = upper($1) AND session_status = 'ACTIVE')`,
					c).Scan(&taken) == nil && !taken {
					code = c
				}
			}
			if code == "" {
				writeJSON(w, http.StatusConflict, errBody("NO_CODE_AVAILABLE",
					"could not find a free session code — try again"))
				return
			}
		}

		now := time.Now().UTC()
		end := now.Add(time.Duration(minutes) * time.Minute)
		_, err = pool.Exec(r.Context(), `
			UPDATE sessions
			   SET session_code        = $2,
			       latitude            = COALESCE($3, latitude),
			       longitude           = COALESCE($4, longitude),
			       gps_accuracy_meters = COALESCE($5, gps_accuracy_meters),
			       radius_meters       = $6,
			       checkin_window_start = COALESCE(checkin_window_start, $7),
			       checkin_window_end   = $8,
			       session_status      = 'ACTIVE'
			 WHERE session_id = $1`,
			sessionID, code, req.Latitude, req.Longitude, req.Accuracy, radius, now, end)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"session_id":    sessionID,
			"session_code":  code,
			"radius_meters": radius,
			"opens_at":      now.Format(time.RFC3339),
			"closes_at":     end.Format(time.RFC3339),
			"has_location":  req.Latitude != nil && req.Longitude != nil,
			"read_it_out":   "Read this code to the class. It works for " + strconv.Itoa(minutes) + " minutes.",
		})
	}
}

// POST /api/v1/attendance/geo-checkin
//
// Body: {session_code, student_id, latitude, longitude, device_id}
//
// Public and rate-limited, like the other student-facing check-in paths: a student holds a
// registration number and a code, not an account session.
func GeoCheckin(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			SessionCode string   `json:"session_code"`
			StudentID   string   `json:"student_id"`
			Latitude    *float64 `json:"latitude"`
			Longitude   *float64 `json:"longitude"`
			DeviceID    string   `json:"device_id"`
		}
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed request"))
			return
		}
		code := checkin.NormaliseSessionCode(req.SessionCode)
		student := strings.TrimSpace(req.StudentID)
		if code == "" || student == "" {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST",
				"the session code and your registration number are both required"))
			return
		}

		var (
			sessionID, tenantID string
			lat, lon            *float64
			radius              int
			winStart, winEnd    *time.Time
		)
		err := pool.QueryRow(r.Context(), `
			SELECT session_id::text, tenant_id::text, latitude, longitude,
			       COALESCE(radius_meters, $2), checkin_window_start, checkin_window_end
			  FROM sessions
			 WHERE upper(session_code) = $1 AND session_status = 'ACTIVE'
			 LIMIT 1`, code, checkin.DefaultRadiusMeters).
			Scan(&sessionID, &tenantID, &lat, &lon, &radius, &winStart, &winEnd)
		if errors.Is(err, pgx.ErrNoRows) {
			// One message for "no such code" and "the register closed", deliberately: telling a
			// stranger which codes exist lets them find a live one by trying.
			logAttempt(r.Context(), pool, attempt{StudentID: student, Code: code,
				Outcome: "REJECTED", Reason: "no open register with that code",
				Lat: req.Latitude, Lon: req.Longitude, DeviceID: req.DeviceID})
			writeJSON(w, http.StatusUnprocessableEntity, errBody("NO_OPEN_SESSION",
				"that code does not match an open register — check it and try again"))
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
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
		if req.Latitude != nil {
			sLat = *req.Latitude
		}
		if req.Longitude != nil {
			sLon = *req.Longitude
		}

		v := checkin.VerifyCheckin(geo, sLat, sLon, time.Now().UTC())
		if !v.OK {
			logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
				StudentID: student, Code: code, Outcome: "REJECTED", Reason: v.Reason,
				Lat: req.Latitude, Lon: req.Longitude, Distance: v.Distance, DeviceID: req.DeviceID})
			writeJSON(w, http.StatusUnprocessableEntity, map[string]interface{}{
				"error": "REJECTED", "message": v.Reason, "distance_meters": v.Distance,
			})
			return
		}

		// ON CONFLICT DO NOTHING on (session, student): a second tap is the same attendance, and
		// the first timestamp is the one that is true. Mirrors U-Panel, whose record id is
		// {sessionId}_{studentId} and so cannot hold a student twice either.
		var logID string
		err = pool.QueryRow(r.Context(), `
			INSERT INTO attendance_logs (
				tenant_id, session_id, student_id, checkin_timestamp, sequence_number,
				entry_method, latitude, longitude, distance_meters, device_id
			)
			SELECT $1::uuid, $2::uuid, $3::text, now(),
			       COALESCE((SELECT MAX(sequence_number) + 1 FROM attendance_logs WHERE session_id = $2::uuid), 1),
			       'AUTHENTICATED', $4, $5, $6, NULLIF($7,'')
			 WHERE NOT EXISTS (
			       SELECT 1 FROM attendance_logs
			        WHERE session_id = $2::uuid AND btrim(lower(student_id)) = btrim(lower($3::text)))
			RETURNING log_id::text`,
			tenantID, sessionID, student, req.Latitude, req.Longitude, v.Distance, req.DeviceID).Scan(&logID)
		if errors.Is(err, pgx.ErrNoRows) {
			logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
				StudentID: student, Code: code, Outcome: "DUPLICATE", Reason: "already present",
				Lat: req.Latitude, Lon: req.Longitude, Distance: v.Distance, DeviceID: req.DeviceID})
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"status": "ALREADY_PRESENT", "session_id": sessionID,
				"distance_meters": v.Distance,
				"message":         "You are already marked present for this lecture.",
			})
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		logAttempt(r.Context(), pool, attempt{TenantID: tenantID, SessionID: sessionID,
			StudentID: student, Code: code, Outcome: "PRESENT",
			Lat: req.Latitude, Lon: req.Longitude, Distance: v.Distance, DeviceID: req.DeviceID})
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"status": "PRESENT", "session_id": sessionID, "log_id": logID,
			"distance_meters": v.Distance,
			"message":         "You are marked present.",
		})
	}
}
