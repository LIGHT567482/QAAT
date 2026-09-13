package handlers

// Admin assignment of the schools a QA monitor covers (migration 110).
//
// The QA officer / patroller / school-handler roles were merged into QA_MONITOR, and with the
// merge the school list stopped being a value on the account: it is a list an ADMIN manages here,
// stored in qa_monitor_schools. That list — NOT users.school — is the scope of every QA dashboard
// and report the monitor reads. A monitor with NO school assigned is institution-wide by design, so
// saving an empty list is a deliberate, valid state, not an error.
//
// This is ADMIN-only, and both endpoints run on the admin (superuser) pool exactly like the rest
// of the Users page — no tenant GUC dance needed, and the qaat_app role never even reaches the
// table. The `users` row must still belong to THIS tenant and be a QA_MONITOR, and every school id
// must name a school of THIS tenant.
//
//   GET /api/v1/admin/users/{user_id}/monitor-schools — what the monitor currently covers
//   PUT /api/v1/admin/users/{user_id}/monitor-schools — replace the whole list

import (
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
)

type monitorSchoolRow struct {
	SchoolID     string `json:"school_id"`
	Name         string `json:"name"`
	Abbreviation string `json:"abbreviation,omitempty"`
}

// ListMonitorSchools — GET /api/v1/admin/users/{user_id}/monitor-schools
func ListMonitorSchools(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := extractPathID(r.URL.Path, "/api/v1/admin/users/", "/monitor-schools")
		if !middleware.ValidTenantID(userID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_USER", "valid user_id required"))
			return
		}
		// Prove the user exists in THIS institution before answering — a foreign id must 404,
		// not come back as an empty school list that reads like a real assignment.
		var role string
		if err := pool.QueryRow(r.Context(),
			`SELECT role::text FROM users WHERE tenant_id = $1 AND user_id = $2::uuid LIMIT 1`,
			tenantID, userID).Scan(&role); err != nil {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "no such user in this institution"))
			return
		}
		out := []monitorSchoolRow{}
		rows, err := pool.Query(r.Context(), `
			SELECT s.school_id::text, s.name, COALESCE(s.abbreviation,'')
			  FROM qa_monitor_schools q
			  JOIN schools s ON s.school_id = q.school_id
			 WHERE q.tenant_id = $1 AND q.user_id = $2::uuid
			 ORDER BY s.name`, tenantID, userID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		defer rows.Close()
		for rows.Next() {
			var s monitorSchoolRow
			if rows.Scan(&s.SchoolID, &s.Name, &s.Abbreviation) == nil {
				out = append(out, s)
			}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"user_id": userID,
			"role":    role,
			"schools": out,
		})
	}
}

// SetMonitorSchools — PUT /api/v1/admin/users/{user_id}/monitor-schools
//
// Replaces the monitor's assignment wholesale with the given school ids (an empty list clears
// it — that is the “whole institution” state). Enforces that the target is a QA_MONITOR of this
// tenant and that every id names a school of this tenant; anything else is an error, never a
// silent partial write.
func SetMonitorSchools(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		userID := extractPathID(r.URL.Path, "/api/v1/admin/users/", "/monitor-schools")
		if !middleware.ValidTenantID(userID) {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_USER", "valid user_id required"))
			return
		}

		var req struct {
			SchoolIDs []string `json:"school_ids"`
		}
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}

		// The target must be a QA monitor of this institution. Only monitors have a school
		// list; assigning schools to a dean or a rep would quietly mean nothing.
		var role string
		if err := pool.QueryRow(r.Context(),
			`SELECT role::text FROM users WHERE tenant_id = $1 AND user_id = $2::uuid LIMIT 1`,
			tenantID, userID).Scan(&role); err != nil {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "no such user in this institution"))
			return
		}
		if role != middleware.RoleQAMonitor {
			writeJSON(w, http.StatusBadRequest, errBody("NOT_A_MONITOR",
				"school assignment only applies to QA monitor accounts"))
			return
		}

		// Deduplicate, reject malformed ids, and confirm every id names a school of THIS tenant
		// in one lookup — so the whole list is verified before any row is touched.
		seen := map[string]bool{}
		ids := make([]string, 0, len(req.SchoolIDs))
		for _, id := range req.SchoolIDs {
			id = strings.TrimSpace(id)
			if id == "" || !middleware.ValidTenantID(id) || seen[id] {
				continue
			}
			seen[id] = true
			ids = append(ids, id)
		}
		resolved := []monitorSchoolRow{}
		if len(ids) > 0 {
			rows, err := pool.Query(r.Context(), `
				SELECT school_id::text, name, COALESCE(abbreviation,'')
				FROM schools
				WHERE tenant_id = $1 AND school_id = ANY($2::uuid[])
				ORDER BY name`, tenantID, ids)
			if err != nil {
				writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
				return
			}
			defer rows.Close()
			for rows.Next() {
				var s monitorSchoolRow
				if rows.Scan(&s.SchoolID, &s.Name, &s.Abbreviation) == nil {
					resolved = append(resolved, s)
				}
			}
		}
		if len(resolved) != len(ids) {
			writeJSON(w, http.StatusBadRequest, errBody("UNKNOWN_SCHOOL",
				"one or more school ids do not belong to this institution — nothing was saved"))
			return
		}

		// Replace the assignment. All-or-nothing on one transaction, so the monitor can never
		// observe the table mid-edit (their scope would flip to nothing then back to the set).
		tx, err := pool.Begin(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "tx"))
			return
		}
		defer tx.Rollback(r.Context()) //nolint:errcheck
		if _, err := tx.Exec(r.Context(),
			`DELETE FROM qa_monitor_schools WHERE tenant_id = $1 AND user_id = $2::uuid`,
			tenantID, userID); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		for _, id := range ids {
			if _, err := tx.Exec(r.Context(), `
				INSERT INTO qa_monitor_schools (tenant_id, user_id, school_id)
				VALUES ($1, $2::uuid, $3::uuid) ON CONFLICT (tenant_id, user_id, school_id) DO NOTHING`,
				tenantID, userID, id); err != nil {
				writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
				return
			}
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "commit"))
			return
		}

		writeJSON(w, http.StatusOK, map[string]interface{}{
			"status":  "SAVED",
			"user_id": userID,
			"schools": resolved,
		})
	}
}
