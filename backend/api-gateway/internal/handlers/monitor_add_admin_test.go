package handlers

import (
	"os"
	"strings"
	"testing"
)

// The QA monitor's in-app reach.
//
// A patroller is now a SENDING role on /api/v1/app-notifications (added alongside QA officer /
// DQA director). Two separate lists have to come along on a phone build: the resolver's `case`
// branch that turns "LECTURER" / "COORDINATOR" into a SQL query, and the `valid` map that decides
// whether that audience is even a legal target for the role. The two live half a file apart, and
// a client can send an audience that passes the map and then silently reaches NOBODY if the
// resolver has no branch for it — the exact failure mode these source checks exist to catch.

func TestPatrollerSender_isWiredInResolverAndValidMap(t *testing.T) {
	src, err := os.ReadFile("app_notifications.go")
	if err != nil {
		t.Fatalf("could not read the resolver source: %v", err)
	}
	resolver := string(src)

	// The `valid` map entry — who a patroller may address.
	validLine := `middleware.RolePatroller: {"LECTURERS": true, "LECTURER": true, "COORDINATORS": true, "COORDINATOR": true}`
	if !strings.Contains(resolver, validLine) {
		t.Errorf("valid map has no patroller audience entry — a monitor composer would be refused outright")
	}

	// The resolver case that executes for a patroller sender.
	if !strings.Contains(resolver, `case middleware.RoleQAOfficer, middleware.RoleDQADirector, middleware.RolePatroller:`) {
		t.Errorf("resolveRecipients has no branch for a QA_PATROLLER sender")
	}
	// And the singular COORDINATOR branch that makes one-person targeting possible.
	if !strings.Contains(resolver, `case "COORDINATORS", "COORDINATOR":`) {
		t.Errorf("resolveRecipients has no COORDINATOR audience branch for the patroller")
	}

	// Route gate: the router must admit the patroller to the send endpoint.
	rsc, err := os.ReadFile("../router/router.go")
	if err != nil {
		t.Fatalf("could not read the router source: %v", err)
	}
	if !strings.Contains(string(rsc), "middleware.RolePatroller)).\n\t\t\tPost(\"/api/v1/app-notifications\"") &&
		!strings.Contains(string(rsc), `middleware.RolePatroller)).
			Post("/api/v1/app-notifications"`) {
		t.Errorf("router does not gate POST /api/v1/app-notifications for the patroller role")
	}
}

// The add-administrator channel's invariants, the add-only contract among them. These are
// deliberate and load-bearing: proving them here keeps a future "convenience" (edit, disable,
// alternate role) from drifting into the phones' capability without an administrator deciding it.
func TestMonitorAddAdmin_isAddOnlyAndRoleLocked(t *testing.T) {
	src, err := os.ReadFile("monitor_add_admin.go")
	if err != nil {
		t.Fatalf("could not read the handler source: %v", err)
	}
	h := string(src)

	// Role-locked: the created account is always ADMIN and the request carries no role field.
	if !strings.Contains(h, `role := "ADMIN"`) {
		t.Errorf("handler no longer hard-codes the ADMIN role — a monitor must never be able to mint another role")
	}
	if strings.Contains(h, `"role"`) && strings.Contains(h, `req.Role`) {
		t.Errorf("handler reads a role from the request — the channel must stay ADMIN-only")
	}

	// Add-only: nothing here may update or delete an account.
	for _, verb := range []string{"PATCH", "DELETE", "UPDATE users", "DELETE FROM"} {
		if strings.Contains(h, verb) {
			t.Errorf("handler contains %q — the monitor channel must be add-only", verb)
		}
	}

	// Every account a monitor creates lands behind force_password_change and is active.
	if !strings.Contains(h, "force_password_change)") || !strings.Contains(h, "true") {
		t.Errorf("monitor-created accounts must be forced to change the public default password")
	}

	// The gate is an early, unconditional check — a disabled institution is refused before any
	// body is read, so there is no request shape that bypasses it.
	if !strings.Contains(h, "SELECT monitors_can_add_admins FROM tenants") {
		t.Errorf("handler no longer reads the tenant switch — the feature must gate on it")
	}

	// Migration ships the switch OFF.
	mig, err := os.ReadFile("../../../../db/migrations/108_monitor_add_admin.sql")
	if err != nil {
		t.Fatalf("could not read migration 108: %v", err)
	}
	if !strings.Contains(string(mig), "DEFAULT false") {
		t.Errorf("migration 108 must ship the switch OFF by default")
	}
}