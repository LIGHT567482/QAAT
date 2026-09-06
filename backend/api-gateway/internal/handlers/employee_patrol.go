package handlers

// The QA monitor's SECOND round: office by office.
//
//	GET  /api/v1/patrol/office/manifest — the employee registry, cached for an offline round.
//	GET  /api/v1/patrol/office/search   — find who to knock for, by name, badge, department or door.
//	POST /api/v1/patrol/office/sync     — ingest a batch of office visits.
//
// WHY THIS EXISTS. Employee attendance in this system is captured entirely by machines: badge
// punches in employee_attendance_logs and the biometric terminal's daily sheet in
// employee_attendance_days. Nobody has ever walked to the door. A badge can be tapped by a
// colleague, and the terminal saying somebody clocked in at 08:00 says nothing about whether they
// were at their desk at 11:00.
//
// The teaching side has had two independent accounts of every lecture since migration 058, and
// they are never merged because the disagreement is the finding. This is the same arrangement for
// offices — see migration 106.
//
// Role: QA_PATROLLER, and everything here goes through checkPatrolDevice and sits behind the same
// PIN gate on the handset as the lecture round. The handset is recorded, not enforced (see
// patrol.go): the PIN is what stands behind an observation about a named person.

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/middleware"
)

// officeAbsenceTarget is who an empty-office notice goes to, and what it is about.
type officeAbsenceTarget struct {
	StaffID    string
	Name       string
	Email      string
	Phone      string
	Department string
	Office     string
	VisitDate  string // YYYY-MM-DD, as filed
	VisitTime  string // HH:MM, as filed
}

// officePerson is one employee as the round sees them.
type officePerson struct {
	StaffID    string `json:"staff_id"`
	FullName   string `json:"full_name"`
	Department string `json:"department"`
	JobTitle   string `json:"job_title"`
	// Where the registry says to look. Empty when it does not know, in which case the monitor
	// types what they found — see migration 106 on why there is no offices registry.
	Office string `json:"office"`
}

// officePeopleSQL is shared by the manifest and the search so the two cannot drift into returning
// different fields for the same person. $1 is the tenant.
const officePeopleSQL = `
	SELECT staff_id, full_name, COALESCE(department,''), COALESCE(job_title,''), COALESCE(office,'')
	FROM employees
	WHERE tenant_id = $1 AND COALESCE(is_active, true) `

// scanOfficePeople drains a query built on officePeopleSQL.
func scanOfficePeople(rows interface {
	Next() bool
	Scan(...interface{}) error
	Close()
}) []officePerson {
	defer rows.Close()
	out := make([]officePerson, 0)
	for rows.Next() {
		var p officePerson
		if rows.Scan(&p.StaffID, &p.FullName, &p.Department, &p.JobTitle, &p.Office) != nil {
			continue
		}
		if strings.TrimSpace(p.StaffID) == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

// OfficeManifest returns the whole active employee registry for the offline round.
//
// THE WHOLE REGISTRY, not a page and not a department. The same reasoning as PatrolManifest
// caching the whole week: a monitor with no signal is exactly the one who cannot fetch the rest,
// and a search over a stale subset answers "nobody by that name" with nothing on screen to say
// that it only looked at part of the institution. A few thousand rows of name and badge is a
// small download and it is right on any corridor it is opened in.
func OfficeManifest(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		if err := checkPatrolDevice(r, conn, tenantID, middleware.GetUserID(r.Context())); err != nil {
			writeDeviceRefusal(w)
			return
		}

		rows, err := conn.Query(r.Context(), officePeopleSQL+` ORDER BY full_name`, tenantID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			// The server's own date, for the same reason the lecture manifest sends its weekday:
			// these run on SIM-less handsets whose clocks drift, and a round filed under the
			// wrong day lands where no report window would ever surface it.
			"date":      clock.Today(),
			"employees": scanOfficePeople(rows),
		})
	}
}

// OfficeSearch finds the person whose door the monitor is standing at.
//
// ONE BOX, not the lecture round's by=lecturer|unit pair. A unit and a lecturer are different
// objects reached from different doors; here there is one object — a person — and several ways to
// name them, and asking the monitor to first classify what they are about to type is a question
// with no useful answer.
//
// THE MATCHING RULE, which the handset's offline search mirrors exactly:
//
//	staff_id                  PREFIX   — read off a badge, and typed partially far more often
//	                                     than in full ("kiu/0" must find KIU/044).
//	name, department, office  CONTAINS — a registry name is "DR ANUMOLU SRINIVASA RAO" and the
//	                                     nameplate says ANUMOLU. Prefix-matching the name would
//	                                     return nothing to a monitor standing at the right door,
//	                                     which reads as "this person does not work here".
//
// The two implementations diverging is a silent failure that shows up only as a monitor being
// told nobody matches, so OfficeSearchMatch on the phone is pinned by a test against this comment.
func OfficeSearch(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := middleware.GetUserID(r.Context())

		q := strings.TrimSpace(r.URL.Query().Get("q"))
		// An empty query returns nothing, deliberately — falling back to "everybody" would
		// reinstate the browse-the-institution screen the lecture round removed, and for the
		// same reason: a record is meant to be the consequence of having gone to a door.
		if q == "" {
			writeJSON(w, http.StatusOK, map[string]interface{}{"query": "", "results": []officePerson{}})
			return
		}

		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		if err := checkPatrolDevice(r, conn, tenantID, userID); err != nil {
			writeDeviceRefusal(w)
			return
		}

		needle := strings.ToLower(strings.TrimSpace(q))
		rows, err := conn.Query(r.Context(), officePeopleSQL+`
			  AND ( btrim(lower(staff_id))                LIKE $2
			     OR btrim(lower(full_name))               LIKE $3
			     OR btrim(lower(COALESCE(department,''))) LIKE $3
			     OR btrim(lower(COALESCE(office,'')))     LIKE $3 )
			ORDER BY full_name
			LIMIT 50`, tenantID, needle+"%", "%"+needle+"%")
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"query": q, "results": scanOfficePeople(rows),
		})
	}
}

// officeVisitIn is one visit as the handset filed it.
type officeVisitIn struct {
	// Minted on the phone, and it IS the server's primary key. This is what makes the upload
	// idempotent: a batch retried after a timeout — the normal case on these connections — must
	// not file the same visit twice, and a correction re-sends the same id.
	VisitID string `json:"visit_id"`
	StaffID string `json:"staff_id"`

	Office       string `json:"office"`
	OfficeSource string `json:"office_source"` // REGISTRY | TYPED
	Status       string `json:"status"`        // AT_OFFICE | ELSEWHERE_ON_DUTY | ABSENT
	FoundAt      string `json:"found_at"`
	Remarks      string `json:"remarks"`

	// The phone's clock. visit_date and visit_time are derived from it server-side rather than
	// sent alongside — there is no timetable here to anchor a date to, so a phone sending a date
	// and a timestamp that disagreed would file a visit on a day it did not happen.
	CapturedAt string `json:"captured_at"` // RFC3339
}

// validOfficeStatus mirrors the CHECK constraint in migration 106. Rejected here as well as there
// so a bad row is skipped with the rest of the batch surviving, rather than the insert failing.
func validOfficeStatus(s string) bool {
	switch s {
	case "AT_OFFICE", "ELSEWHERE_ON_DUTY", "ABSENT":
		return true
	}
	return false
}

// OfficeSync ingests a batch of office visits, stamping the monitor's identity from the token.
func OfficeSync(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := middleware.GetUserID(r.Context())

		var body struct {
			Visits []officeVisitIn `json:"visits"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}

		conn, err := pool.Acquire(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		defer conn.Release()
		if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "db unavailable"))
			return
		}
		if err := checkPatrolDevice(r, conn, tenantID, userID); err != nil {
			writeDeviceRefusal(w)
			return
		}
		deviceHash := deviceFingerprint(r)

		// The monitor's display identity, resolved once from the TOKEN. Never from the body: a
		// visit names a person and says whether they were at their desk, and who filed it is not
		// something the filing client gets to assert.
		var monitorName, monitorStaffID string
		_ = conn.QueryRow(r.Context(),
			`SELECT COALESCE(full_name,''), COALESCE(staff_id,'') FROM users WHERE user_id = $1::uuid`,
			userID).Scan(&monitorName, &monitorStaffID)

		var tenantName string
		_ = conn.QueryRow(r.Context(),
			`SELECT COALESCE(name,'') FROM tenants WHERE tenant_id = $1`, tenantID).Scan(&tenantName)

		written := 0
		for _, v := range body.Visits {
			v.VisitID = strings.TrimSpace(v.VisitID)
			v.StaffID = strings.TrimSpace(v.StaffID)
			v.Status = strings.ToUpper(strings.TrimSpace(v.Status))
			if v.VisitID == "" || v.StaffID == "" || !validOfficeStatus(v.Status) {
				continue
			}
			if v.OfficeSource != "REGISTRY" {
				v.OfficeSource = "TYPED"
			}

			// The employee's details come from the REGISTRY, not from the phone. The handset's
			// copy may be a week old, and a visit naming a department the person has since left is
			// a visit filed against the wrong office. This is also where the contact details for
			// the notification come from, so a staff id the registry does not know is skipped
			// rather than filed: an observation about somebody the institution cannot identify is
			// an accusation with no addressee.
			var name, dept, job, email, phone string
			if conn.QueryRow(r.Context(), `
				SELECT full_name, COALESCE(department,''), COALESCE(job_title,''),
				       COALESCE(email,''), COALESCE(phone,'')
				FROM employees
				WHERE tenant_id = $1 AND btrim(lower(staff_id)) = btrim(lower($2))
				LIMIT 1`, tenantID, v.StaffID).Scan(&name, &dept, &job, &email, &phone) != nil {
				continue
			}

			// visitDate/visitTime come back from the row rather than being re-derived here, so
			// the message quotes the moment that was actually filed — clamp and all.
			var inserted bool
			var visitDate, visitTime string
			execErr := conn.QueryRow(r.Context(), `
				INSERT INTO employee_patrol_logs
				  (visit_id, tenant_id, staff_id, employee_name, department, job_title,
				   office, office_source, status, found_at, remarks,
				   captured_at, visit_date, visit_time,
				   patroller_id, patroller_name, patroller_staff_id, patroller_device_hash)
				SELECT $1::uuid, $2, $3, $4, $5, $6,
				       $7, $8, $9, $10, $11,
				       c.at, c.at::date, to_char(c.at, 'HH24:MI'),
				       $13::uuid, $14, $15, $16
				  FROM (SELECT
				        -- The monitor works offline, so the phone's clock is the real record of
				        -- when the visit happened and a PAST timestamp is kept as given. A FUTURE
				        -- one is a wrong device clock, not evidence, so it is clamped to now
				        -- rather than filed under a day that has not happened — where no report
				        -- window would ever surface it.
				        LEAST(COALESCE(NULLIF($12,'')::timestamptz, now()), now()) AS at) c
				ON CONFLICT (visit_id) DO UPDATE
				   SET status                = EXCLUDED.status,
				       found_at              = EXCLUDED.found_at,
				       office                = EXCLUDED.office,
				       office_source         = EXCLUDED.office_source,
				       remarks               = EXCLUDED.remarks,
				       captured_at           = EXCLUDED.captured_at,
				       visit_date            = EXCLUDED.visit_date,
				       visit_time            = EXCLUDED.visit_time,
				       employee_name         = EXCLUDED.employee_name,
				       department            = EXCLUDED.department,
				       job_title             = EXCLUDED.job_title,
				       patroller_id          = EXCLUDED.patroller_id,
				       patroller_name        = EXCLUDED.patroller_name,
				       patroller_staff_id    = EXCLUDED.patroller_staff_id,
				       patroller_device_hash = EXCLUDED.patroller_device_hash
				RETURNING (xmax = 0), visit_date::text, visit_time`,
				v.VisitID, tenantID, v.StaffID, name, dept, job,
				strings.TrimSpace(v.Office), v.OfficeSource, v.Status,
				strings.TrimSpace(v.FoundAt), strings.TrimSpace(v.Remarks),
				v.CapturedAt,
				userID, monitorName, monitorStaffID, deviceHash).Scan(&inserted, &visitDate, &visitTime)

			if execErr != nil {
				// 23505 is ux_employee_visit_moment: this monitor already has a visit to this
				// person in this minute under a different id — a double tap that minted two ids.
				// COUNT IT WRITTEN. The observation is on file under the first id, and a phone
				// that treated this as a failure would retry that row for the life of the queue.
				var pgErr *pgconn.PgError
				if errors.As(execErr, &pgErr) && pgErr.Code == "23505" {
					written++
				}
				// Anything else: skip this row and keep the batch. One malformed visit must not
				// cost a monitor the rest of a morning's round.
				continue
			}
			written++

			// The person is told only when the office was empty — see employee_patrol_notify.go
			// for what that message may and may not say. Called on every ABSENT row rather than
			// only on inserts: a correction that flips ELSEWHERE→ABSENT must still reach them,
			// and AlreadySent is the single source of truth for "have we told them about today".
			// Best-effort throughout — a failure here never fails the sync.
			if v.Status == "ABSENT" {
				notifyOfficeAbsence(r, pool, tenantID, tenantName, officeAbsenceTarget{
					StaffID:    v.StaffID,
					Name:       name,
					Email:      email,
					Phone:      phone,
					Department: dept,
					Office:     strings.TrimSpace(v.Office),
					VisitDate:  visitDate,
					VisitTime:  visitTime,
				})
			}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"status": "SYNCED", "records_written": written,
		})
	}
}
