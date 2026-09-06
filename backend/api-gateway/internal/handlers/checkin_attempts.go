package handlers

// ── STUDENT MODULE: DEFERRED TO V2 ───────────────────────────────────────────────────────────
//
// Nothing in this file is reachable in v1. KIU QAAT ships as an internal Quality Assurance
// system, and every route that reached these handlers is commented out in
// internal/router/router.go. The code is retained, not deleted: it still compiles and its tests
// still run, so restoring the module is uncommenting its routes rather than rewriting it.

// KEEPING WHAT WAS REFUSED.
//
// A rejected check-in used to vanish. The student saw a message and the system kept nothing, which
// meant the most common attendance dispute — "I was there and it would not mark me present" — had
// no evidence on either side. An absence caused by a failed attempt looked exactly like an absence
// caused by not turning up.
//
// So every attempt is recorded, accepted or refused, with the reason and the distance. Two things
// fall out of that which are worth more than the dispute case:
//
//   A lecturer can see that forty students were refused at 1600 metres. That is not forty student
//   problems; it is one session opened at the wrong coordinates, and it is invisible without this.
//
//   A student refused twenty times in a minute from three kilometres away is a different story from
//   one refused once at 1520 metres, and the register alone cannot tell them apart.
//
// Logging never blocks the answer. If writing the attempt fails the student is still told what
// happened — an audit trail that could refuse a legitimate check-in would be worse than no audit
// trail at all.

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type attempt struct {
	TenantID  string
	SessionID string // empty when the typed code matched nothing — kept anyway, see above
	StudentID string
	Code      string
	Outcome   string // PRESENT | DUPLICATE | REJECTED
	Reason    string
	Lat, Lon  *float64
	Distance  int
	DeviceID  string
	Offline   bool
	At        time.Time
}

// logAttempt records one attempt. Errors are deliberately swallowed: see the note above.
func logAttempt(ctx context.Context, pool *pgxpool.Pool, a attempt) {
	if pool == nil {
		return
	}
	if a.At.IsZero() {
		a.At = time.Now().UTC()
	}
	// A tenant is required by the column; an attempt on a code that matched nothing has none to
	// borrow, so it falls back to the single institution rather than being dropped.
	tid := a.TenantID
	if tid == "" {
		tid = singleTenantID(ctx, pool)
		if tid == "" {
			return
		}
	}
	_, _ = pool.Exec(ctx, `
		INSERT INTO checkin_attempts (
			tenant_id, session_id, student_id, session_code, outcome, reason,
			latitude, longitude, distance_meters, device_id, captured_offline,
			attempted_at, received_at
		) VALUES ($1::uuid, NULLIF($2,'')::uuid, $3, $4, $5, $6, $7, $8, $9, NULLIF($10,''), $11, $12, now())`,
		tid, a.SessionID, a.StudentID, a.Code, a.Outcome, a.Reason,
		a.Lat, a.Lon, a.Distance, a.DeviceID, a.Offline, a.At)
}

// GET /api/v1/attendance/attempts?session_id=&student_id=&failed_only=&days=
//
// The log, read back. Two questions it exists to answer, and the filters mirror them exactly:
// "what happened on this register" (session_id) and "what happened to this student" (student_id).
//
// failed_only defaults to FALSE. A log that showed only failures would answer "were there
// problems" but not "how many of the attempts were problems", and forty rejections mean something
// entirely different in a hall of forty than in a hall of four hundred.
func ListCheckinAttempts(pool *pgxpool.Pool) http.HandlerFunc {
	type row struct {
		AttemptID string   `json:"attempt_id"`
		SessionID string   `json:"session_id"`
		StudentID string   `json:"student_id"`
		Code      string   `json:"session_code"`
		Outcome   string   `json:"outcome"`
		Reason    string   `json:"reason"`
		Distance  *int     `json:"distance_meters"`
		DeviceID  string   `json:"device_id"`
		Offline   bool     `json:"captured_offline"`
		At        string   `json:"attempted_at"`
		Lat       *float64 `json:"latitude,omitempty"`
		Lon       *float64 `json:"longitude,omitempty"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		days := 7
		if n := atoiSafe(strings.TrimSpace(q.Get("days"))); n >= 1 && n <= 180 {
			days = n
		}
		args := []interface{}{days}
		sql := `SELECT attempt_id::text, COALESCE(session_id::text,''), student_id, session_code,
		               outcome, reason, distance_meters, COALESCE(device_id,''), captured_offline,
		               attempted_at, latitude, longitude
		          FROM checkin_attempts
		         WHERE attempted_at >= now() - make_interval(days => $1)`
		if v := strings.TrimSpace(q.Get("session_id")); v != "" {
			args = append(args, v)
			sql += " AND session_id = $" + strconv.Itoa(len(args)) + "::uuid"
		}
		if v := strings.TrimSpace(q.Get("student_id")); v != "" {
			args = append(args, v)
			sql += " AND btrim(lower(student_id)) = btrim(lower($" + strconv.Itoa(len(args)) + "))"
		}
		if strings.EqualFold(strings.TrimSpace(q.Get("failed_only")), "true") {
			sql += " AND outcome <> 'PRESENT'"
		}
		sql += " ORDER BY attempted_at DESC LIMIT 500"

		rows, err := pool.Query(r.Context(), sql, args...)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		defer rows.Close()
		out := []row{}
		var present, failed int
		for rows.Next() {
			var x row
			var at time.Time
			if rows.Scan(&x.AttemptID, &x.SessionID, &x.StudentID, &x.Code, &x.Outcome, &x.Reason,
				&x.Distance, &x.DeviceID, &x.Offline, &at, &x.Lat, &x.Lon) != nil {
				continue
			}
			x.At = at.Format(time.RFC3339)
			if x.Outcome == "PRESENT" {
				present++
			} else {
				failed++
			}
			out = append(out, x)
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"attempts": out, "total": len(out), "accepted": present, "refused": failed, "days": days,
		})
	}
}
