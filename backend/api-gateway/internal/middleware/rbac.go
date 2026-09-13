package middleware

import (
	"encoding/json"
	"net/http"
)

// RequireRole returns a middleware that allows only the listed roles.
// JWTAuth must run first (it sets CtxRole in the context).
func RequireRole(roles ...string) func(http.Handler) http.Handler {
	allowed := make(map[string]struct{}, len(roles))
	for _, r := range roles {
		allowed[r] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			role := GetRole(r.Context())
			if _, ok := allowed[role]; !ok {
				// Transition window (migration 110): a JWT minted under a legacy QA field
				// role label is a monitor. It counts as QA_MONITOR for any gate that admits
				// one — and for no other gate, so the DQA-only surfaces stay shut.
				if _, legacy := legacyMonitorRoles[role]; legacy {
					if _, ok := allowed[RoleQAMonitor]; ok {
						next.ServeHTTP(w, r)
						return
					}
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusForbidden)
				json.NewEncoder(w).Encode(map[string]string{ //nolint:errcheck
					"error":   "INSUFFICIENT_ROLE",
					"message": "your role does not have access to this resource",
				})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Role constants — single source of truth used by route definitions.
const (
	RoleCoordinator = "COORDINATOR"
	RoleDQADirector = "DQA_DIRECTOR"
	RoleVC          = "VC"
	RoleDVC         = "DVC" // Deputy Vice-Chancellor (oversight tier, mirrors VC)
	RoleAdmin       = "ADMIN"
	RoleStudent     = "STUDENT"
	RoleLecturer    = "LECTURER"   // logs into the lecturer dashboard (read-only attendance)
	RoleQAMonitor   = "QA_MONITOR" // QA field monitor — the three legacy QA field roles merged (migration 110)
	RoleHOD         = "HOD"        // Head of Department — oversees lecturers in ONE department
	RoleDean        = "DEAN"       // Dean — oversees departments/lecturers in ONE school/college
	RoleQADeptRep   = "QA_DEPT_REP"
	// RoleTLC — Teaching & Learning Centre. The timetable's owner. It used to be
	// the IT administrator's job by default, which is an accident of who had the
	// button rather than whose work it is; the TLC maintains the schedule.
	RoleTLC = "TLC"

	// The legacy QA field roles, merged into RoleQAMonitor by migration 110. No account
	// carries these labels any more; they survive so RequireRole's alias above can translate a
	// token minted before the merge, and so a gate can name the old role explicitly if it ever
	// needs to.
	RoleQAOfficer = "QA_OFFICER"
	RolePatroller = "QA_PATROLLER"
	RoleQASchool  = "QA_SCHOOL_HANDLER"
)

// legacyMonitorRoles: every label a QA monitor's wallet might still hold after migration 110.
// RequireRole maps them onto RoleQAMonitor so a token signed before the merge keeps working
// through the deploy window instead of 403ing the person who signed in an hour ago.
var legacyMonitorRoles = map[string]struct{}{
	RoleQAMonitor: {},
	RoleQAOfficer: {},
	RolePatroller: {},
	RoleQASchool:  {},
}
