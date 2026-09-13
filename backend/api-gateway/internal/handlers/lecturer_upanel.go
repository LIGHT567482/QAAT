package handlers

// THE U-PANEL REGISTER — the lecturer's side of the in-room hub.
//
//   GET/POST logic lives here for the U-Panel attendance model (migration 109):
//
//     POST /api/v1/lecturer/sessions/open          open the register for an attendance list
//     POST /api/v1/lecturer/sessions/{id}/close    close it, which books the contact hours
//     POST /api/v1/attendance/hub-checkin          one LIVE check-in through the shared verifier
//
// WHY A LIST AND NOT A TIMETABLE SLOT. U-Panel opens sessions under attendance_lists — a
// (cohort, unit) roster named by its year/semester/program — and the lecturer is the person
// physically holding the room. Every coordinator-opened session relies on "the coordinator is the
// person holding the door"; a register is the lecturer's own, so their attendance is stamped from
// the moment they open it and the session_ code is what the class types on the hub.
//
// WHO MAY OPEN. The list's own lecturer, or a lecturer assigned to the list's unit. QA,
// coordinators and admin may open on behalf of a list's lecturer (the dashboards that run a
// register on the lecturer's behalf do this). A lecturer cannot open a list they have no
// relationship to — that would turn the register into a way to accept attendance for another
// lecturer's class.

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/checkin"
	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/middleware"
	"github.com/qaat/attendance"
)

// lecturerOpenSessionRequest is what the PWA/portal sends to open a register.
type lecturerOpenSessionRequest struct {
	ListID            string   `json:"list_id"`
	Latitude          *float64 `json:"latitude"`
	Longitude         *float64 `json:"longitude"`
	RadiusMeters      *int     `json:"radius_meters"`
	GPSAccuracyMeters *int     `json:"gps_accuracy_meters"`
	OpenMinutes       *int     `json:"open_minutes"`
}

// lecturerOpenSessionResponse is the wire shape for open (fresh or already open) and is also
// what close answers with. already_open=true means a register was already running under this list
// and the response IS that register — the caller must not mint a second one.
type lecturerOpenSessionResponse struct {
	SessionID        string `json:"session_id"`
	ListID           string `json:"list_id"`
	UnitID           string `json:"unit_id"`
	UnitName         string `json:"unit_name"`
	SessionCode      string `json:"session_code"` // the static spoken code students type on the hub
	CheckinCode      string `json:"checkin_code"` // the rotating coordinator-side code, live for ~30s
	SecondsRemaining int    `json:"seconds_remaining"`
	CheckinWindowEnd string `json:"checkin_window_end"`
	AlreadyOpen      bool   `json:"already_open"`
	Present          int    `json:"present"`
	Enrolled         int    `json:"enrolled"`
}

// attendanceList is the U-Panel checklist row a register opens under.
type attendanceList struct {
	listID     string
	offeringID string // the cohort; isolates a shared unit's Day/Evening/Weekend rosters
	unitID     string
	unitName   string
	lecturerID string
}

// resolveAttendanceList reads one roster, joining its display name from the unit.
func resolveAttendanceList(ctx context.Context, conn *pgxpool.Conn, tenantID, listID string) (attendanceList, error) {
	var l attendanceList
	err := conn.QueryRow(ctx, `
		SELECT al.list_id::text, al.offering_id::text, al.unit_id,
		       COALESCE(cu.name, al.unit_id), COALESCE(al.lecturer_id::text, '')
		FROM attendance_lists al
		LEFT JOIN course_units cu ON cu.unit_id = al.unit_id AND cu.tenant_id = al.tenant_id
		WHERE al.list_id = $1::uuid AND al.tenant_id = $2`,
		listID, tenantID).Scan(&l.listID, &l.offeringID, &l.unitID, &l.unitName, &l.lecturerID)
	return l, err
}

// lecturerMayOpenList proves a lecturer has a right to this roster: they are the list's own
// lecturer, or they are assigned to the list's unit.
func lecturerMayOpenList(ctx context.Context, conn *pgxpool.Conn, tenantID, listID, unitID, lecturerID string) (bool, error) {
	var ok bool
	err := conn.QueryRow(ctx, `
		SELECT EXISTS(
			SELECT 1 FROM attendance_lists al
			 WHERE al.list_id = $1::uuid AND al.tenant_id = $2
			   AND ( al.lecturer_id::text = $3
			         OR EXISTS (SELECT 1 FROM lecturer_assignments la
			                     WHERE la.tenant_id = $2 AND la.lecturer_id::text = $3
			                       AND la.unit_id = $4) ) )`,
		listID, tenantID, lecturerID, unitID).Scan(&ok)
	return ok, err
}

// isPrivilegedOpener: staff who may open or close a register on a lecturer's behalf.
// This is exactly the set the router gives the /lecturer/sessions routes — a role changed
// here without a matching route change gets a 403 from RequireRole, not a surprise opening.
func isPrivilegedOpener(role string) bool {
	switch role {
	case middleware.RoleCoordinator, middleware.RoleQAMonitor,
		middleware.RoleDQADirector, middleware.RoleAdmin:
		return true
	}
	return false
}

// openSessionMinutes picks the register window: the tenant's policy by default, overridable per
// open but never beyond four hours (an hour-long lecture with a forgotten lock means an hour, not
// a day).
func openSessionMinutes(ctx context.Context, conn *pgxpool.Conn, tenantID string, requested *int) int {
	var minutes int
	if err := conn.QueryRow(ctx,
		`SELECT checkin_window_minutes FROM tenants WHERE tenant_id = $1`, tenantID).
		Scan(&minutes); err != nil || minutes <= 0 {
		minutes = 30
	}
	if requested != nil && *requested > 0 {
		minutes = *requested
	}
	if minutes > 240 {
		minutes = 240
	}
	return minutes
}

// POST /api/v1/lecturer/sessions/open
func LecturerOpenSession(pool, adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := middleware.GetUserID(r.Context())
		role := middleware.GetRole(r.Context())

		var req lecturerOpenSessionRequest
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}
		listID := strings.TrimSpace(req.ListID)
		if listID == "" || !middleware.ValidTenantID(listID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "list_id is required"))
			return
		}

		// A lecturer proves they may run this roster; privileged staff may open on its
		// lecturer's behalf. Anyone else has no business with a register.
		lecturerID := ""
		if role == middleware.RoleLecturer {
			var ok bool
			lecturerID, ok = resolveLecturerID(adminPool, r, tenantID, userID)
			if !ok {
				writeJSON(w, http.StatusForbidden, errBody("NOT_A_LECTURER",
					"no lecturer record is linked to this account"))
				return
			}
		} else if !isPrivilegedOpener(role) {
			writeJSON(w, http.StatusForbidden, errBody("INSUFFICIENT_ROLE",
				"your role cannot open a register"))
			return
		}

		// Decision D: the daily session window still gates a physical room being opened at
		// three in the morning, exactly as it gates the coordinator's open.
		if open, msg := withinSessionWindow(r.Context(), pool, tenantID); !open {
			writeJSON(w, http.StatusConflict, errBody("WINDOW_CLOSED", msg))
			return
		}

		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}

		list, err := resolveAttendanceList(r.Context(), conn, tenantID, listID)
		if errors.Is(err, pgx.ErrNoRows) {
			writeJSON(w, http.StatusNotFound, errBody("LIST_NOT_FOUND", "no attendance list matches that id"))
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		if lecturerID != "" {
			ok, lerr := lecturerMayOpenList(r.Context(), conn, tenantID, listID, list.unitID, lecturerID)
			if lerr != nil {
				writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", lerr.Error()))
				return
			}
			if !ok {
				writeJSON(w, http.StatusForbidden, errBody("NOT_ASSIGNED",
					"you are not the list's lecturer or assigned to its unit"))
				return
			}
		}

		// The register's lecturer: the opener when they are one, otherwise the list's own.
		effectiveLecturerID := lecturerID
		if effectiveLecturerID == "" {
			effectiveLecturerID = list.lecturerID
		}

		now := time.Now().UTC()
		minutes := openSessionMinutes(r.Context(), conn, tenantID, req.OpenMinutes)
		windowEnd := now.Add(time.Duration(minutes) * time.Minute)

		tx, err := conn.Begin(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}
		defer tx.Rollback(context.Background()) //nolint:errcheck

		// Same lock discipline as OpenSession, keyed on the list: two taps arriving together —
		// a double-tap, or the portal retrying on a bad hotspot — must not produce two registers.
		if _, err := tx.Exec(r.Context(),
			`SELECT pg_advisory_xact_lock(hashtext($1 || ':list:' || $2))`, tenantID, listID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}

		// Idempotent open: a register already running under this list is returned, not duplicated.
		// Duplicating would split the roster in two and show the class a code it cannot use.
		var (
			existingID       string
			existingCode     string
			existingSecret   []byte
			existingEnd      time.Time
			existingPresent  int
			existingEnrolled int
		)
		err = tx.QueryRow(r.Context(), `
			SELECT s.session_id::text, COALESCE(s.session_code, ''),
			       COALESCE(s.checkin_secret, ''), COALESCE(s.checkin_window_end, now()),
			       (SELECT COUNT(*) FROM attendance_logs al WHERE al.session_id = s.session_id),
			       (SELECT COUNT(*) FROM students_extended se
			         WHERE se.offering_id = s.offering_id AND se.enrollment_status = 'ACTIVE')
			FROM sessions s
			WHERE s.list_id = $1::uuid AND s.tenant_id = $2
			  AND s.session_status IN ('ACTIVE', 'PENDING_LECTURER') AND s.finalized = false
			LIMIT 1`, listID, tenantID).Scan(&existingID, &existingCode, &existingSecret,
			&existingEnd, &existingPresent, &existingEnrolled)
		if err == nil {
			writeJSON(w, http.StatusOK, lecturerOpenSessionResponse{
				SessionID: existingID, ListID: listID, UnitID: list.unitID, UnitName: list.unitName,
				SessionCode: existingCode, CheckinCode: checkin.Derive(existingSecret, now),
				SecondsRemaining: checkin.SecondsRemaining(now),
				CheckinWindowEnd: existingEnd.Format(time.RFC3339),
				AlreadyOpen:      true, Present: existingPresent, Enrolled: existingEnrolled,
			})
			return
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}

		// Mint the spoken code. The unique index ux_sessions_active_code is global across ACTIVE
		// sessions, so the collision probe must be tenant-blind — one tenant must not hand its
		// class a code another tenant's register is already showing.
		code := ""
		for attempt := 0; attempt < 8 && code == ""; attempt++ {
			c, gerr := checkin.NewSessionCode(4)
			if gerr != nil {
				writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
				return
			}
			var taken bool
			if adminPool.QueryRow(r.Context(),
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

		radius := checkin.DefaultRadiusMeters
		if req.RadiusMeters != nil && *req.RadiusMeters > 0 {
			radius = *req.RadiusMeters
		}

		var sessionID string
		// coordinator_id is the opener's own user id (half the vector-clock key on
		// attendance_logs) — mirroring StartOnlineClass, where the person opening IS the
		// coordinator of record. Using the list's offering coordinator would collide with that
		// coordinator's own open session in the one-open-session rule.
		err = tx.QueryRow(r.Context(), `
			INSERT INTO sessions
			    (tenant_id, coordinator_id, unit_id, lecturer_id, session_date,
			     gate_open_time, checkin_window_start, checkin_window_end,
			     session_status, checkin_secret, offering_id, delivery_mode,
			     session_code, latitude, longitude, radius_meters, gps_accuracy_meters,
			     list_id, opened_by, opened_at)
			SELECT $1, $2, al.unit_id, NULLIF($3, ''), $4, $5, $5, $6, 'ACTIVE', $7,
			       al.offering_id, 'IN_PERSON', $8,
			       $9::double precision, $10::double precision, $11, $12::integer,
			       $13::uuid, $14::uuid, $5
			FROM attendance_lists al
			WHERE al.list_id = $13::uuid AND al.tenant_id = $1
			RETURNING session_id::text`,
			tenantID, userID, effectiveLecturerID, clock.Today(), now, windowEnd, secret, code,
			req.Latitude, req.Longitude, radius, req.GPSAccuracyMeters, listID, userID).Scan(&sessionID)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("OPEN_FAILED",
				"could not open the register (check the list exists for this tenant)"))
			return
		}

		// The register's lecturer is present from this moment. lecturer_scanned_at is the column
		// every report and the missed-class list read, and opening the register means the same
		// thing a scan did: this named person began teaching. The contact hours are booked when
		// the register closes.
		if effectiveLecturerID != "" {
			if _, err := tx.Exec(r.Context(), `
				INSERT INTO lecturer_attendance_logs
				    (tenant_id, session_id, lecturer_id, gate_open_time, unit_id, session_date,
				     lecturer_scanned_at)
				SELECT $1, $2, $3, $4, al.unit_id, $5, $4
				FROM attendance_lists al
				WHERE al.list_id = $6::uuid AND al.tenant_id = $1
				ON CONFLICT DO NOTHING`,
				tenantID, sessionID, effectiveLecturerID, now, clock.Today(), listID); err != nil {
				writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR",
					"could not record your attendance"))
				return
			}
		}

		var enrolled int
		_ = tx.QueryRow(r.Context(),
			`SELECT COUNT(*) FROM students_extended se
			  WHERE se.offering_id = $1::uuid AND se.enrollment_status = 'ACTIVE'`,
			list.offeringID).Scan(&enrolled)

		if err := tx.Commit(r.Context()); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not open the register"))
			return
		}

		writeJSON(w, http.StatusCreated, lecturerOpenSessionResponse{
			SessionID: sessionID, ListID: listID, UnitID: list.unitID, UnitName: list.unitName,
			SessionCode: code, CheckinCode: checkin.Derive(secret, now),
			SecondsRemaining: checkin.SecondsRemaining(now),
			CheckinWindowEnd: windowEnd.Format(time.RFC3339),
			AlreadyOpen:      false, Present: 0, Enrolled: enrolled,
		})
	}
}

// POST /api/v1/lecturer/sessions/{session_id}/close
//
// Closing books the contact hours in lecturer_attendance_logs and marks the session CLOSED for
// good (finalized), exactly as ending the online class ends it. A register is an in-room fact, so
// — unlike the remote class, which has no independent witness and demands a quorum — no quorum is
// applied here: the QA patrol is the independent witness a physical room already has.
func LecturerCloseSession(pool, adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := middleware.GetUserID(r.Context())
		role := middleware.GetRole(r.Context())

		sessionID := strings.TrimSpace(chi.URLParam(r, "session_id"))
		if sessionID == "" || !middleware.ValidTenantID(sessionID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "a valid session id is required"))
			return
		}

		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not close the register"))
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "could not close the register"))
			return
		}

		var openedBy, sessionLecturer, status string
		var present int
		err = conn.QueryRow(r.Context(), `
			SELECT COALESCE(s.opened_by::text, ''), COALESCE(s.lecturer_id::text, ''),
			       s.session_status::text,
			       (SELECT COUNT(*) FROM attendance_logs al WHERE al.session_id = s.session_id)
			FROM sessions s
			WHERE s.session_id = $1::uuid AND s.tenant_id = $2
			  AND s.session_status IN ('ACTIVE', 'PENDING_LECTURER') AND s.finalized = false`,
			sessionID, tenantID).Scan(&openedBy, &sessionLecturer, &status, &present)
		if errors.Is(err, pgx.ErrNoRows) {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "no open register matches that session"))
			return
		}
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		// Closers: whoever opened the register, the register's own lecturer, or privileged staff.
		// A coordinator who opened on a lecturer's behalf is letting the lecturer finish it.
		canClose := isPrivilegedOpener(role) || openedBy == userID
		if !canClose && role == middleware.RoleLecturer {
			if lecturerID, ok := resolveLecturerID(adminPool, r, tenantID, userID); ok && lecturerID == sessionLecturer {
				canClose = true
			}
		}
		if !canClose {
			writeJSON(w, http.StatusForbidden, errBody("NOT_SESSION_OPENER",
				"only the person who opened this register, its lecturer, or staff may close it"))
			return
		}

		now := time.Now().UTC()
		tag, err := conn.Exec(r.Context(), `
			UPDATE sessions SET session_status = 'CLOSED', gate_close_time = $1,
			       coordinator_end_time = $1, finalized = true
			 WHERE session_id = $2::uuid AND tenant_id = $3
			   AND session_status IN ('ACTIVE', 'PENDING_LECTURER')`,
			now, sessionID, tenantID)
		if err != nil || tag.RowsAffected() == 0 {
			writeJSON(w, http.StatusConflict, errBody("ALREADY_CLOSED", "the register is already closed"))
			return
		}

		// Book the contact hours — the point of closing at all.
		if _, err := conn.Exec(r.Context(), `
			UPDATE lecturer_attendance_logs
			   SET gate_close_time = $1, lecturer_ended_at = $1,
			       contact_hours = ROUND(EXTRACT(EPOCH FROM ($1 - gate_open_time)) / 3600.0, 2)
			 WHERE session_id = $2::uuid AND tenant_id = $3 AND lecturer_ended_at IS NULL`,
			now, sessionID, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		// Tell the students who did not check in. Best-effort — the close already happened.
		_ = notifyAbsentStudents(r.Context(), adminPool, sessionID, tenantID)

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"session_id": sessionID, "status": "CLOSED",
			"closed_at": now.Format(time.RFC3339), "checkin_count": present,
		})
	}
}

// POST /api/v1/attendance/hub-checkin
//
// ONE live check-in from the in-room hub, judged by the SHARED verifier
// (github.com/qaat/attendance — the Go port of U-Panel's maybe_process_check_in) so the live
// gateway and the offline sync-receiver hand out the same verdict for the same facts. Public and
// rate-limited, like every student-facing path: a student holds a registration number and a code,
// not an account session.
//
// HOW THE TENANT IS LEARNED. A student has no JWT. The code is resolved on adminPool
// (BYPASSRLS): ux_sessions_active_code makes one typed code name exactly one ACTIVE session across
// the whole deployment, and that session names its tenant. The verifier's own session lookups then
// run on an RLS connection pinned to that tenant, so a check-in can only ever judge the register it
// resolves to. An unresolved code rejects without a tenant and leaves a kept refusal via the
// single-institution fallback (singleTenantID) — checkin_attempts exists to prove "nobody could
// get in".
type hubCheckinRequest struct {
	SessionID         string  `json:"session_id"` // claimed session; optional when the code resolves
	SessionCode       string  `json:"session_code"`
	StudentID         string  `json:"student_id"` // registration number, typed on the hub
	Latitude          float64 `json:"latitude"`
	Longitude         float64 `json:"longitude"`
	GPSAccuracyMeters float64 `json:"gps_accuracy_meters"`
	DeviceID          string  `json:"device_id"` // the hub's own id — NOT a per-student phone
	DeviceFingerprint string  `json:"device_fingerprint_hash"`
	CheckinTimestamp  string  `json:"checkin_timestamp"` // optional; server time is the truth live
}

type hubCheckinResponse struct {
	Status         string `json:"status"` // PRESENT | DUPLICATE | REJECTED | PENDING
	Reason         string `json:"reason,omitempty"`
	SessionID      string `json:"session_id,omitempty"`
	ListID         string `json:"list_id,omitempty"`
	LogID          string `json:"log_id,omitempty"`
	DistanceMeters int    `json:"distance_meters,omitempty"`
	Message        string `json:"message,omitempty"`
}

func HubCheckin(pool, adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req hubCheckinRequest
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}
		student := strings.TrimSpace(req.StudentID)
		code := checkin.NormaliseSessionCode(req.SessionCode)
		claimedID := strings.TrimSpace(req.SessionID)
		if student == "" || (claimedID == "" && code == "") {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST",
				"the registration number and a session id or code are required"))
			return
		}
		if claimedID != "" && !middleware.ValidTenantID(claimedID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "not a valid session id"))
			return
		}

		now := time.Now().UTC()
		captured := attendance.ParseTimestamp(req.CheckinTimestamp)

		// ── Resolve tenant + the facts the verdict row needs (assignments, ordering) ──
		var sessionID, tenantID, coordinatorID string
		if claimedID != "" {
			err := adminPool.QueryRow(r.Context(), `
				SELECT session_id::text, tenant_id::text, COALESCE(coordinator_id::text, '')
				FROM sessions WHERE session_id = $1::uuid`, claimedID).
				Scan(&sessionID, &tenantID, &coordinatorID)
			if err != nil {
				// A stale or foreign claim: nothing to judge against, and no tenant to record a
				// refusal into — the engine's answer is the closest truthful one.
				writeJSON(w, http.StatusUnprocessableEntity, hubCheckinResponse{
					Status: "REJECTED", Reason: "session does not match",
				})
				return
			}
		} else if err := adminPool.QueryRow(r.Context(), `
			SELECT session_id::text, tenant_id::text, COALESCE(coordinator_id::text, '')
			FROM sessions
			WHERE upper(session_code) = upper($1) AND session_status = 'ACTIVE'
			LIMIT 1`, code).Scan(&sessionID, &tenantID, &coordinatorID); err != nil {
			// Kept refusal: the code matched nothing, and that is evidence, not noise.
			logAttempt(r.Context(), adminPool, attempt{StudentID: student, Code: code,
				Outcome: "REJECTED", Reason: "no open register with that code",
				Lat: floatPtr(req.Latitude), Lon: floatPtr(req.Longitude),
				Distance: 0, DeviceID: req.DeviceID, At: now})
			writeJSON(w, http.StatusUnprocessableEntity, hubCheckinResponse{
				Status: "REJECTED", Reason: "no open register with that code",
				Message: "that code does not match an open register — check it and try again",
			})
			return
		}

		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, hubCheckinResponse{Status: "REJECTED", Reason: "INTERNAL_ERROR"})
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, hubCheckinResponse{Status: "REJECTED", Reason: "INTERNAL_ERROR"})
			return
		}

		// Same lookup/dedup shape the sync-receiver drives (student_checkin.go), so both paths
		// answer identically. The hub is a shared station, so the one-device-one-person rule is
		// deliberately off — students type on one device, the rule would reject the whole hall.
		lookup := attendance.Lookup{
			ByID: func(id string) *attendance.Session {
				return loadHubSession(r.Context(), conn, tenantID, id)
			},
			ByCode: func(norm string) *attendance.Session {
				return loadHubSessionByCode(r.Context(), conn, tenantID, norm)
			},
		}
		decision := attendance.Evaluate(
			attendance.Attempt{
				StudentID:         student,
				DeviceID:          strings.TrimSpace(req.DeviceID),
				Latitude:          req.Latitude,
				Longitude:         req.Longitude,
				GPSAccuracyMeters: req.GPSAccuracyMeters,
				CapturedAt:        captured,
				ReceivedAt:        &now,
				SessionID:         sessionID,
				SessionCode:       code,
				AwaitingSession:   false,
			},
			lookup,
			attendance.Facts{
				Now: now,
				RecordExists: func(sid, reg string) bool {
					var exists bool
					if qerr := conn.QueryRow(r.Context(),
						`SELECT EXISTS(SELECT 1 FROM attendance_logs
						   WHERE session_id = $1::uuid AND student_id = $2)`,
						sid, reg).Scan(&exists); qerr != nil {
						return false // optimistic: the ledger's own dedup decides
					}
					return exists
				},
				DeviceUsedByOther: func(_, _, _ string) bool { return false },
			},
		)

		verdictSessionID := decision.SessionID
		if verdictSessionID == "" {
			verdictSessionID = sessionID
		}

		switch decision.Verdict {
		case attendance.VerdictPending:
			// Live, this is unreachable (AwaitingSession is false); kept so a claim the sweep
			// later resolves is never burnt.
			if cerr := insertHubAttempt(r.Context(), conn, tenantID, verdictSessionID, student,
				code, decision, "PENDING", true, now, captured, req); cerr == nil {
				writeJSON(w, http.StatusAccepted, hubCheckinResponse{
					Status: "PENDING", SessionID: verdictSessionID,
					Message: "waiting for the register to open — we will record you",
				})
				return
			}

		case attendance.VerdictRejected:
			if cerr := insertHubAttempt(r.Context(), conn, tenantID, verdictSessionID, student,
				code, decision, "REJECTED", false, now, captured, req); cerr != nil {
				writeJSON(w, http.StatusInternalServerError, hubCheckinResponse{Status: "REJECTED", Reason: "INTERNAL_ERROR"})
				return
			}
			writeJSON(w, http.StatusUnprocessableEntity, hubCheckinResponse{
				Status: "REJECTED", Reason: decision.Reason, ListID: decision.ListID,
				SessionID: verdictSessionID, DistanceMeters: decision.DistanceMeters,
			})
			return
		}

		// ACCEPTED or DUPLICATE: stamp the attempt row first so the verdict has an audit trail
		// even if the ledger write below races with another tap.
		outcome := "PRESENT"
		if decision.Verdict == attendance.VerdictDuplicate {
			outcome = "DUPLICATE"
		}
		if cerr := insertHubAttempt(r.Context(), conn, tenantID, verdictSessionID, student,
			code, decision, outcome, false, now, captured, req); cerr != nil {
			writeJSON(w, http.StatusInternalServerError, hubCheckinResponse{Status: "REJECTED", Reason: "INTERNAL_ERROR"})
			return
		}

		if decision.Verdict == attendance.VerdictDuplicate {
			writeJSON(w, http.StatusOK, hubCheckinResponse{
				Status: "DUPLICATE", SessionID: verdictSessionID, ListID: decision.ListID,
				DistanceMeters: decision.DistanceMeters,
				Message:        "You are already marked present for this lecture.",
			})
			return
		}

		// ACCEPTED: a new ledger row. HUB_VERIFIED is the label migration 109 introduced for
		// verifier-written records; it sits outside the QR_SCAN/AUTHENTICATED unique indexes,
		// so the Engine's RecordExists is the dedup — a second tap answers DUPLICATE before
		// ever reaching here.
		entryMethod := "HUB_VERIFIED"
		if strings.TrimSpace(req.DeviceFingerprint) != "" {
			entryMethod = "AUTHENTICATED"
		}
		var logID string
		qerr := conn.QueryRow(r.Context(), `
			INSERT INTO attendance_logs
			    (tenant_id, session_id, student_id, checkin_timestamp,
			     captured_at, received_at, entry_method,
			     device_fingerprint_hash, device_id, latitude, longitude, distance_meters,
			     sequence_number, coordinator_id)
			VALUES ($1, $2::uuid, $3,
			        COALESCE($4::timestamptz, $5::timestamptz), $4::timestamptz, $5::timestamptz,
			        $6::entry_method_enum, NULLIF($7, ''), NULLIF($8, ''),
			        $9::double precision, $10::double precision, $11::integer,
			        (SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM attendance_logs
			          WHERE session_id = $2::uuid),
			        NULLIF($12, ''))
			RETURNING log_id::text`,
			tenantID, verdictSessionID, student, captured, now,
			entryMethod, strings.TrimSpace(req.DeviceFingerprint), strings.TrimSpace(req.DeviceID),
			nullableFloatHub(req.Latitude), nullableFloatHub(req.Longitude),
			decision.DistanceMeters, coordinatorID).Scan(&logID)
		if qerr != nil {
			// A concurrent duplicate landing between the engine's EXISTS and this INSERT trips a
			// unique index or the RecordExists is stale — treat it as the same attendance.
			writeJSON(w, http.StatusOK, hubCheckinResponse{
				Status: "DUPLICATE", SessionID: verdictSessionID, ListID: decision.ListID,
				Message: "You are already marked present for this lecture.",
			})
			return
		}

		writeJSON(w, http.StatusOK, hubCheckinResponse{
			Status: "PRESENT", SessionID: verdictSessionID, ListID: decision.ListID,
			LogID: logID, DistanceMeters: decision.DistanceMeters,
			Message: "You are marked present.",
		})
	}
}

// insertHubAttempt records one verdict on checkin_attempts. A refusal is evidence and is kept,
// never discarded (migration 104). Mirrors the sync-receiver's upsertAttempt.
func insertHubAttempt(ctx context.Context, conn *pgxpool.Conn, tenantID, sessionID, studentID,
	code string, decision attendance.Decision, outcome string, awaiting bool, now time.Time,
	captured *time.Time, req hubCheckinRequest) error {
	_, qerr := conn.Exec(ctx, `
		INSERT INTO checkin_attempts
		  (tenant_id, session_id, student_id, session_code, outcome,
		   reason, latitude, longitude, distance_meters, device_id, captured_offline,
		   attempted_at, received_at, awaiting_session, list_id, resolved_at)
		VALUES ($1, NULLIF($2, '')::uuid, $3, $4, $5, $6,
		        $7::double precision, $8::double precision, $9::integer, NULLIF($10, ''),
		        false,
		        COALESCE($11::timestamptz, $12::timestamptz), $12::timestamptz,
		        $13::boolean, NULLIF($14, '')::uuid,
		        CASE WHEN NOT $13::boolean THEN now() ELSE NULL END)`,
		tenantID, sessionID, studentID, code, outcome, decision.Reason,
		nullableFloatHub(req.Latitude), nullableFloatHub(req.Longitude),
		nullableIntHub(decision.DistanceMeters), strings.TrimSpace(req.DeviceID),
		captured, now, awaiting, decision.ListID)
	return qerr
}

// loadHubSession and loadHubSessionByCode are the api-gateway copies of the sync-receiver's
// verifier loaders: same columns, same rules, same engine answers. ByID returns any status and
// lets the engine's window/status rules judge; ByCode only ever returns ACTIVE sessions
// (ux_sessions_active_code).
func loadHubSession(ctx context.Context, conn *pgxpool.Conn, tenantID, id string) *attendance.Session {
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
		FROM sessions WHERE tenant_id = $1::uuid AND session_id = $2::uuid`,
		tenantID, id).Scan(&s.ID, &listID, &code, &status, &start, &end, &lat, &lon, &radius, &acc)
	if err != nil {
		return nil
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
	// A register opened without a fix cannot be geofenced; accepting on the code and the window
	// is honest (weak signal is not absence), matching the engine's LocationMetadataPending.
	if s.Latitude == 0 && s.Longitude == 0 {
		s.LocationMetadataPending = true
	}
	return &s
}

func loadHubSessionByCode(ctx context.Context, conn *pgxpool.Conn, tenantID, norm string) *attendance.Session {
	var id sql.NullString
	err := conn.QueryRow(ctx, `
		SELECT session_id::text FROM sessions
		WHERE tenant_id = $1::uuid AND upper(session_code) = upper($2)
		  AND session_status = 'ACTIVE'
		ORDER BY created_at DESC LIMIT 1`, tenantID, norm).Scan(&id)
	if err != nil {
		return nil
	}
	return loadHubSession(ctx, conn, tenantID, id.String)
}

// floatPtr and friends keep the small nullable helpers local to this file; they mirror the
// pointer-passthrough convention the codebase uses for *float64 columns.
func floatPtr(f float64) *float64 {
	if f == 0 {
		return nil
	}
	return &f
}

func nullableFloatHub(f float64) *float64 { return floatPtr(f) }
func nullableIntHub(v int) *int           { return &v }
