package handlers

// The monitor add-administrator feature.
//
// A QA monitor walking the offices round is the person physically present when an office finds
// its administrator is unreachable — nobody can request staff access, nobody approves exams, and
// the only person who could fix it is out of reach. "Add an administrator" is a phone action for
// exactly that moment: the monitor types a name, an email address and the office, and the system
// provisions a NEW ADMINISTRATOR whose first login lands them inside the admin dashboards.
//
// Deliberate limits keep this channel honest:
//
//   - ADD-ONLY. Nothing on the phone can edit or remove an account. "Remove someone" is a
//     deliberate management act with paper trails and handover implications; a corridor observer
//     must never be able to do it, and must never look able to.
//   - GATED OFF BY DEFAULT. The whole feature hangs off `tenants.monitors_can_add_admins`, which
//     is false on every tenant until an administrator flips it (admin settings). A monitor who
//     finds the switch off gets a plain refusal and can do nothing about it.
//   - ROLE-LOCKED. The account created is always ADMIN. No other role is reachable, so a monitor
//     can never mint themselves a second identity or promote an accomplice.
//   - ONE-WORD FIRST LOGIN. The new account starts on the public staff default with
//     force_password_change set, exactly like an imported account — it gets the person in once
//     and is replaced before they reach any role UI. The monitor tells the office the word; the
//     account cannot do anything until that first sign-in happens.
//
// The office round already partners the monitor's presence with a live rotating code, but the
// create itself is a QA_MONITOR-role request behind the switch — the QA_MONITOR role gate plus
// the per-tenant switch is the whole check.

import (
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

// GET /api/v1/patrol/office/can-add-admins — QA_MONITOR.
//
// Answers the single question the offices round needs: "is the institution allowing me to create
// an administrator from here?" The answer is the tenant switch, nothing more.
func CanMonitorAddAdmins(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		enabled := false
		if err := pool.QueryRow(r.Context(),
			`SELECT monitors_can_add_admins FROM tenants WHERE tenant_id = $1`, tenantOf(r),
		).Scan(&enabled); err != nil {
			log.Printf("can-add-admins: tenant lookup failed: %v", err)
			// A tenant that does not read back is a tenant in a bad place. Default to OFF — the
			// safe answer for an add-only channel is always "no".
			writeJSON(w, http.StatusOK, map[string]interface{}{"enabled": false, "default_password": DefaultStaffPassword})
			return
		}
		// The public default word is part of the answer so the round can show the monitor what to
		// tell the office. It is public knowledge by identical design to the imports; the account
		// cannot reach any role UI until the person replaces it at first sign-in.
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"enabled":          enabled,
			"default_password": DefaultStaffPassword,
		})
	}
}

// POST /api/v1/patrol/office/add-admin — QA_MONITOR + tenant switch.
//
// Creates one ADMINISTRATOR account. Full name and email are required; department is optional
// and names the office. The account is active immediately and starts on the public staff default,
// forced to change it at first sign-in.
func MonitorAddAdmin(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Feature gate first: the switch is OFF by default and only an administrator can turn it
		// on. A monitor hitting an OFF institution is refused outright and told whom to ask.
		var enabled bool
		if err := pool.QueryRow(r.Context(),
			`SELECT monitors_can_add_admins FROM tenants WHERE tenant_id = $1`, tenantOf(r),
		).Scan(&enabled); err != nil || !enabled {
			writeJSON(w, http.StatusForbidden, errBody("ADD_ADMINS_DISABLED",
				"Adding administrators from the round is turned off. Ask an administrator to enable it in settings."))
			return
		}

		var req struct {
			FullName   string `json:"full_name"`
			Email      string `json:"email"`
			Department string `json:"department"`
		}
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}
		req.FullName = strings.TrimSpace(req.FullName)
		req.Email = strings.ToLower(strings.TrimSpace(req.Email))
		req.Department = strings.TrimSpace(req.Department)
		if req.FullName == "" || req.Email == "" {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "full_name and email are required"))
			return
		}

		// The role is hard-coded to ADMIN — a monitor can only ever create an administrator.
		// There is no request field for it precisely so there is nothing to get wrong.
		role := "ADMIN"

		// Same institution-domain rule every account satisfies.
		var domain string
		if err := pool.QueryRow(r.Context(),
			`SELECT domain FROM tenants WHERE tenant_id = $1`, tenantOf(r)).Scan(&domain); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("TENANT_NOT_FOUND", "tenant not found"))
			return
		}
		domain = strings.ToLower(strings.TrimSpace(domain))
		if !emailInDomain(req.Email, domain) {
			writeJSON(w, http.StatusBadRequest, errBody("EMAIL_DOMAIN_MISMATCH",
				"email must use the institution domain @"+domain))
			return
		}

		// The seed word for "administrator created for someone else": no human chose it. The
		// account cannot reach any role UI until this is replaced at first sign-in.
		password := ImportedPasswordFor(role)
		hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", "password hashing failed"))
			return
		}

		var userID string
		err = pool.QueryRow(r.Context(), `
			INSERT INTO users (tenant_id, email, password_hash, role, full_name, is_active,
			                   department, force_password_change)
			VALUES ($1,$2,$3,$4,$5,true,NULLIF($6,''),true)
			RETURNING user_id::text`,
			tenantOf(r), req.Email, string(hash), role, req.FullName, req.Department,
		).Scan(&userID)
		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" && strings.Contains(pgErr.ConstraintName, "email") {
				var holderName, holderRole string
				_ = pool.QueryRow(r.Context(),
					`SELECT COALESCE(full_name,''), role::text
					   FROM users WHERE tenant_id = $1 AND lower(email) = lower($2)`,
					tenantOf(r), req.Email).Scan(&holderName, &holderRole)
				msg := req.Email + " is already in use"
				if holderRole != "" {
					msg += " by " + orDash(holderName) + " (" + humanRole(holderRole) + ")"
				}
				writeJSON(w, http.StatusConflict, errBody("EMAIL_TAKEN", msg+"."))
				return
			}
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"status":           "ADMIN_CREATED",
			"user_id":          userID,
			"email":            req.Email,
			"role":             role,
			"default_password": password,
			"message":          "Administrator created. They sign in once with this email and the word \"" + password + "\", and must replace it at first sign-in.",
		})
	}
}

// GET /api/v1/admin/settings/monitor-add-admins — ADMIN.
func GetMonitorAddAdminsSetting(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		enabled := false
		_ = pool.QueryRow(r.Context(),
			`SELECT monitors_can_add_admins FROM tenants WHERE tenant_id = $1`, tenantOf(r)).Scan(&enabled)
		writeJSON(w, http.StatusOK, map[string]bool{"enabled": enabled})
	}
}

// PUT /api/v1/admin/settings/monitor-add-admins — ADMIN.
//
// The one switch that powers the whole feature. OFF by default; an administrator turns it on (and
// back off). There is deliberately no per-user toggle — the add-or-not decision is the institution's.
func PutMonitorAddAdminsSetting(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled bool `json:"enabled"`
		}
		if err := decodeJSON(r, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed body"))
			return
		}
		_, err := pool.Exec(r.Context(),
			`UPDATE tenants SET monitors_can_add_admins = $1 WHERE tenant_id = $2`,
			body.Enabled, tenantOf(r))
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"enabled": body.Enabled})
	}
}
