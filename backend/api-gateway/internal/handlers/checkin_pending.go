package handlers

// THE PENDING / OFFLINE QUEUE, READ BACK.
//
// A student who types a code before the lecturer has opened the register is not
// refused outright and forgotten. The check-in is parked as a claim
// (checkin_attempts.awaiting_session = true, resolved_at NULL) and the sweep job
// retries it every minute — if the session opens within the window the claim
// resolves into a normal attempt, otherwise it stays parked until it ages out.
// The same phone that queues those claims also queues check-ins captured with no
// signal (captured_offline = true) and drains them when it is back online.
//
// This screen is the queue itself, so an oversight role can see the attempts that
// have not landed in the register yet and tell "still waiting" from "went through".
// It exists next to the main attempts log, never merged into it: an unresolved
// claim is not evidence of presence, and a resolved one becomes an ordinary row in
// ListCheckinAttempts.

import (
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// GET /api/v1/attendance/pending?days=&status=
//
// status is one of "pending" (awaiting its session), "offline" (drained from a
// phone queue) or "all" (default); days bounds the lookback like ListCheckinAttempts.
func ListCheckinPending(pool *pgxpool.Pool) http.HandlerFunc {
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
		Awaiting  bool     `json:"awaiting_session"`
		ListID    string   `json:"list_id"`
		At        string   `json:"attempted_at"`
		Received  string   `json:"received_at"`
		Resolved  *string  `json:"resolved_at"`
		Lat       *float64 `json:"latitude,omitempty"`
		Lon       *float64 `json:"longitude,omitempty"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		days := 7
		if n := atoiSafe(strings.TrimSpace(q.Get("days"))); n >= 1 && n <= 180 {
			days = n
		}
		status := strings.ToLower(strings.TrimSpace(q.Get("status")))
		sql := `SELECT attempt_id::text, COALESCE(session_id::text,''), student_id, session_code,
		               outcome, reason, distance_meters, COALESCE(device_id,''), captured_offline,
		               awaiting_session, COALESCE(list_id::text,''), attempted_at, received_at,
		               resolved_at, latitude, longitude
		          FROM checkin_attempts
		         WHERE attempted_at >= now() - make_interval(days => $1)`
		if status == "pending" {
			sql += " AND awaiting_session = true AND resolved_at IS NULL"
		} else if status == "offline" {
			sql += " AND captured_offline = true"
		} else {
			sql += " AND (awaiting_session = true OR captured_offline = true)"
		}
		sql += " ORDER BY received_at DESC LIMIT 500"

		rows, err := pool.Query(r.Context(), sql, days)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		defer rows.Close()
		out := []row{}
		var pending, offline int
		for rows.Next() {
			var x row
			var at, received time.Time
			var resolved *time.Time
			if rows.Scan(&x.AttemptID, &x.SessionID, &x.StudentID, &x.Code, &x.Outcome, &x.Reason,
				&x.Distance, &x.DeviceID, &x.Offline, &x.Awaiting, &x.ListID, &at, &received,
				&resolved, &x.Lat, &x.Lon) != nil {
				continue
			}
			x.At = at.Format(time.RFC3339)
			x.Received = received.Format(time.RFC3339)
			if resolved != nil {
				rs := resolved.Format(time.RFC3339)
				x.Resolved = &rs
			}
			if x.Awaiting && x.Resolved == nil {
				pending++
			}
			if x.Offline {
				offline++
			}
			out = append(out, x)
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"attempts": out, "total": len(out), "pending": pending, "offline": offline, "days": days,
		})
	}
}
