package auth

import (
	"regexp"
	"strings"
)

// This file ports the login-identifier resolution order fixed by
// docs/qaat-spec/05-auth-and-roles.md §2. The current Django source is
// backend/accounts/services/login_identifier.py. Failure at every step always
// yields the same 401 "Wrong email or password." — no user enumeration.

// staffNumberRe matches the admin registration pattern KIU\d+[A-Z] (step 5).
var staffNumberRe = regexp.MustCompile(`^KIU\d+[A-Z]$`)

// NormalizeStaffNumber canonicalizes any accepted staff-number input to the
// KIU-#### form. Accepts "KIU-0001", "KIU0001", "0001" (step 3).
func NormalizeStaffNumber(raw string) string {
	s := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(raw), " ", ""))
	if s == "" {
		return ""
	}
	// Strip a leading KIU / KIU- prefix, keep the numeric core.
	core := strings.TrimPrefix(strings.TrimPrefix(s, "KIU-"), "KIU")
	if core == s {
		core = s
	}
	// If the core is purely numeric, zero-pad to 4 and re-prefix.
	if regexp.MustCompile(`^\d+$`).MatchString(core) {
		for len(core) < 4 {
			core = "0" + core
		}
		return "KIU-" + core
	}
	// Otherwise return the uppercased original.
	return s
}

// SyntheticStaffEmail builds the non-mailbox synthetic address for a staff
// number: <local>@staff.qaat.local (step 4). QAAT rename of staff.upanel.local.
func SyntheticStaffEmail(staffNumber string) string {
	local := strings.TrimPrefix(NormalizeStaffNumber(staffNumber), "KIU-")
	return local + "@staff.qaat.local"
}

// IsSyntheticStaffEmail reports whether an address is in the synthetic staff
// domain. Password-reset emails must ignore these (spec doc 05 §6).
func IsSyntheticStaffEmail(email string) bool {
	return strings.HasSuffix(strings.ToLower(strings.TrimSpace(email)), "@staff.qaat.local")
}

// LooksLikeAdminPattern reports whether the identifier matches the admin
// registration pattern (step 5).
func LooksLikeAdminPattern(ident string) bool {
	return staffNumberRe.MatchString(strings.ToUpper(strings.TrimSpace(ident)))
}
