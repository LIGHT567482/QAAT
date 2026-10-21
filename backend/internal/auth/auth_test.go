package auth

import "testing"

// TestNormalizeStaffNumber locks the staff-number canonicalization of spec
// doc 05 §2 step 3: KIU-0001 / KIU0001 / 0001 all -> KIU-0001.
func TestNormalizeStaffNumber(t *testing.T) {
	cases := map[string]string{
		"KIU-0001": "KIU-0001",
		"KIU0001":  "KIU-0001",
		"0001":     "KIU-0001",
		"k i u 0001": "KIU-0001",
		"1":        "KIU-0001",
		"":         "",
	}
	for in, want := range cases {
		if got := NormalizeStaffNumber(in); got != want {
			t.Errorf("NormalizeStaffNumber(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSyntheticStaffEmail(t *testing.T) {
	if got := SyntheticStaffEmail("0001"); got != "0001@staff.qaat.local" {
		t.Errorf("SyntheticStaffEmail = %q", got)
	}
	if !IsSyntheticStaffEmail("0001@staff.qaat.local") {
		t.Error("expected synthetic staff email to be recognized")
	}
	if IsSyntheticStaffEmail("real@kiu.ac.ug") {
		t.Error("real email must not be synthetic")
	}
}

// TestRoleDerivedFlags locks the derived flags of spec doc 05 §1.
func TestRoleDerivedFlags(t *testing.T) {
	if !RoleQAStaff.IsAdministrator() || !RoleAdministrator.IsAdministrator() || !RoleKIUAdmin.IsAdministrator() {
		t.Error("qa_staff/administrator/kiu_admin must be administrators")
	}
	if RoleStudent.IsAdministrator() || RoleLecturer.IsAdministrator() {
		t.Error("student/lecturer must not be administrators")
	}
	if !(RoleLecturer.HasLecturerAttendanceAccess() && RoleKIUAdmin.HasLecturerAttendanceAccess()) {
		t.Error("lecturer and kiu_admin must have lecturer attendance access")
	}
	if RoleStudent.HasLecturerAttendanceAccess() {
		t.Error("student must not have lecturer attendance access")
	}
	if !RoleQAStaff.HasStaffOperationalAccess() || RoleKIUAdmin.HasStaffOperationalAccess() {
		t.Error("staff operational access is qa_staff|administrator only")
	}
}

func TestRoleValid(t *testing.T) {
	for _, r := range []Role{RoleStudent, RoleLecturer, RoleQAStaff, RoleAdministrator, RoleKIUAdmin} {
		if !r.Valid() {
			t.Errorf("%s should be valid", r)
		}
	}
	if Role("coordinator").Valid() {
		t.Error("legacy coordinator role must not be valid")
	}
	if Role("SUPER_ADMIN").Valid() {
		t.Error("legacy SUPER_ADMIN role must not be valid")
	}
}
