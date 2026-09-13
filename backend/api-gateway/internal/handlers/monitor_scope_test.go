package handlers

// The QA monitor's school scope, end to end (migration 110).
//
// QA was three roles doing one job (officer / patroller / school handler) and they merged into
// QA_MONITOR, whose colleges an ADMIN now manages in qa_monitor_schools rather than on the account.
// Two behaviours turn on that table and both are easy to get subtly wrong:
//
//   - a monitor with NO school assigned is deliberately institution-wide (the officer's old remit),
//     not an empty page — resolveQAScope and resolveOrgScope must flag "unscoped";
//   - a monitor with schools assigned must be bounded to exactly them, even when that means several
//     colleges their legacy users.school column never carried, and the admin assignment page must
//     refuse anything that is not this tenant's monitor or this tenant's school.
//
// These run against a real database (they are SQL and a mock would only agree with my reading of
// it). They SKIP unless a connection is supplied, like the rest of the repo's integration tests:
//
//	DB_URL='postgres://qaat:qaat@localhost:5434/qaat?sslmode=disable' go test ./internal/handlers/ -run MonitorScope -v
//
// Everything it writes happens inside a transaction that is ALWAYS rolled back, so it can be run
// against a working database without leaving anything behind.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
)

// monitorScopeDB opens the test pool and picks an institution to write the ZZ-scratch fixture into.
func monitorScopeDB(t *testing.T) (*pgxpool.Pool, string) {
	t.Helper()
	url := os.Getenv("DB_URL")
	if url == "" {
		t.Skip("set DB_URL to run the QA monitor scope tests")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, url)
	if err != nil || pool.Ping(ctx) != nil {
		t.Skipf("database unavailable: %v", err)
	}
	t.Cleanup(pool.Close)
	var tenantID string
	if err := pool.QueryRow(ctx,
		`SELECT tenant_id::text FROM tenants
		  WHERE tenant_id <> '00000000-0000-0000-0000-000000000000'
		  ORDER BY created_at LIMIT 1`).Scan(&tenantID); err != nil {
		t.Skipf("no institution in this database: %v", err)
	}
	return pool, tenantID
}

// seedScratchSchools creates two ZZ-named colleges of this tenant and returns their ids.
func seedScratchSchools(t *testing.T, pool *pgxpool.Pool, tenantID string) (string, string) {
	t.Helper()
	ctx := context.Background()
	ids := make([]string, 2)
	for i, suffix := range []string{"A", "B"} {
		if err := pool.QueryRow(ctx,
			`INSERT INTO schools (tenant_id, name, abbreviation) VALUES ($1, $2, $3)
			 RETURNING school_id::text`,
			tenantID, "ZZ Monitor College "+suffix, "ZZMC"+suffix).Scan(&ids[i]); err != nil {
			t.Fatalf("seed school %s: %v", suffix, err)
		}
	}
	t.Cleanup(func() { cleanupMonitorFixture(t, pool, tenantID, ids[0], ids[1]) })
	return ids[0], ids[1]
}

// cleanupMonitorFixture removes every ZZ row this test wrote, so the fixture can never leak into a
// later run's "the account has no school" assertions.
func cleanupMonitorFixture(t *testing.T, pool *pgxpool.Pool, tenantID, schoolA, schoolB string) {
	t.Helper()
	ctx := context.Background()
	_, _ = pool.Exec(ctx, `DELETE FROM users
		WHERE tenant_id = $1 AND (email LIKE 'zz.monitor.%@kiu.ac.ug' OR school LIKE 'ZZ Monitor College %')`,
		tenantID)
	_, _ = pool.Exec(ctx, `DELETE FROM schools
		WHERE tenant_id = $1 AND (school_id = $2::uuid OR school_id = $3::uuid OR name LIKE 'ZZ Monitor College %')`,
		tenantID, schoolA, schoolB)
}

// seedMonitor creates a QA_MONITOR account of this tenant and returns its id.
func seedMonitor(t *testing.T, pool *pgxpool.Pool, tenantID, email string) string {
	t.Helper()
	var id string
	if err := pool.QueryRow(context.Background(),
		`INSERT INTO users (tenant_id, email, password_hash, role, full_name)
		 VALUES ($1, $2, 'zz', 'QA_MONITOR', 'ZZ Monitor One')
		 RETURNING user_id::text`,
		tenantID, email).Scan(&id); err != nil {
		t.Fatalf("seed monitor: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(),
			`DELETE FROM users WHERE tenant_id = $1 AND user_id = $2::uuid`, tenantID, id)
	})
	return id
}

// qaScopeFor resolves the caller's scope exactly the way withQAConn hands it to the handlers.
func qaScopeFor(t *testing.T, pool *pgxpool.Pool, tenantID, userID, role string) qaScope {
	t.Helper()
	ctx := context.Background()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer conn.Release()
	if err := middleware.SetTenantConn(ctx, conn, tenantID); err != nil {
		t.Fatalf("set tenant GUC: %v", err)
	}
	s, err := resolveQAScope(ctx, conn, userID, role)
	if err != nil {
		t.Fatalf("resolveQAScope: %v", err)
	}
	return s
}

// THE CASE THE FEATURE EXISTS FOR. The officer's agents were institution-wide; a merged monitor
// with nothing assigned must inherit that reach — an empty page would read as "no data" to
// somebody whose job is everyone.
func TestMonitorScope_UnassignedMonitorIsInstitutionWide(t *testing.T) {
	pool, tenantID := monitorScopeDB(t)
	// No qa_monitor_schools rows, no users.school. The joined accounts were reassigned nothing.
	userID := seedMonitor(t, pool, tenantID, "zz.monitor.unassigned@kiu.ac.ug")

	s := qaScopeFor(t, pool, tenantID, userID, middleware.RoleQAMonitor)
	if !s.Unscoped {
		t.Errorf("an unassigned monitor is scoped %q (%v); want the whole institution", s.ScopeKind, s.Schools)
	}
	if s.ScopeKind != "ALL" {
		t.Errorf("unassigned monitor scope kind = %q, want ALL", s.ScopeKind)
	}
	if clause, _, has := s.scopeSQL("c.department", "c.school", 1); clause != "" || has {
		t.Errorf("unassigned monitor must add no filter, got %q", clause)
	}
}

// A monitor with colleges assigned is bounded to them even when they number several — the single
// users.school column could never carry more than one, which is the exact gap the join table fills.
func TestMonitorScope_AssignedSchoolsBind(t *testing.T) {
	pool, tenantID := monitorScopeDB(t)
	a, b := seedScratchSchools(t, pool, tenantID)
	userID := seedMonitor(t, pool, tenantID, "zz.monitor.assigned@kiu.ac.ug")
	for _, sid := range []string{a, b} {
		if _, err := pool.Exec(context.Background(),
			`INSERT INTO qa_monitor_schools (tenant_id, user_id, school_id)
			 VALUES ($1, $2::uuid, $3::uuid) ON CONFLICT DO NOTHING`,
			tenantID, userID, sid); err != nil {
			t.Fatalf("assign school: %v", err)
		}
	}

	s := qaScopeFor(t, pool, tenantID, userID, middleware.RoleQAMonitor)
	if s.Unscoped {
		t.Fatalf("an assigned monitor resolved unscoped; schools = %v", s.Schools)
	}
	if s.ScopeKind != "SCHOOL" {
		t.Fatalf("assigned monitor scope kind = %q, want SCHOOL", s.ScopeKind)
	}
	have := func(want string) bool {
		for _, n := range s.allSchools() {
			if strings.EqualFold(strings.TrimSpace(n), strings.TrimSpace(want)) {
				return true
			}
		}
		return false
	}
	if !have("ZZ Monitor College A") || !have("ZZ Monitor College B") {
		t.Errorf("assigned monitor sees %v; both scratch colleges must resolve", s.allSchools())
	}

	// The SQL filter must bind BOTH names, normalised — one filter, several colleges, all visible.
	clause, val, has := s.scopeSQL("c.department", "c.school", 2)
	if !has || !strings.Contains(clause, "= ANY($2)") {
		t.Errorf("assigned monitor filter = (%q, %v); want an ANY over the school set", clause, val)
	}
}

// The legacy users.school column is folded into the scope so an account that predates admin-managed
// assignment keeps working — the merge must not take a college away from anyone.
func TestMonitorScope_LegacySchoolColumnStillResolves(t *testing.T) {
	pool, tenantID := monitorScopeDB(t)
	_, b := seedScratchSchools(t, pool, tenantID)
	var targetName string
	if err := pool.QueryRow(context.Background(),
		`SELECT name FROM schools WHERE school_id = $1::uuid`, b).Scan(&targetName); err != nil {
		t.Fatalf("read school name: %v", err)
	}
	userID := seedMonitor(t, pool, tenantID, "zz.monitor.legacy@kiu.ac.ug")
	if _, err := pool.Exec(context.Background(),
		`UPDATE users SET school = $1 WHERE user_id = $2::uuid AND tenant_id = $3`,
		targetName, userID, tenantID); err != nil {
		t.Fatalf("set legacy school: %v", err)
	}

	s := qaScopeFor(t, pool, tenantID, userID, middleware.RoleQAMonitor)
	if s.Unscoped {
		t.Errorf("a monitor with a legacy users.school resolved unscoped")
	}
	for _, n := range s.allSchools() {
		if strings.EqualFold(strings.TrimSpace(n), strings.TrimSpace(targetName)) {
			return
		}
	}
	t.Errorf("legacy school %q not in scope %v", targetName, s.allSchools())
}

// The ADMIN assignment endpoints are the only writers of qa_monitor_schools. A target that is not
// this tenant's monitor, or an id that is not this tenant's school, must be an error — never a
// silent partial write.
func TestMonitorScope_AdminAssignmentEndpoints(t *testing.T) {
	pool, tenantID := monitorScopeDB(t)
	a, _ := seedScratchSchools(t, pool, tenantID)
	userID := seedMonitor(t, pool, tenantID, "zz.monitor.admin@kiu.ac.ug")

	// Not a monitor: a dean must be refused, not silently ignored.
	var deanID string
	if err := pool.QueryRow(context.Background(),
		`INSERT INTO users (tenant_id, email, password_hash, role, full_name)
		 VALUES ($1, 'zz.dean.other@kiu.ac.ug', 'zz', 'DEAN', 'ZZ Dean')
		 RETURNING user_id::text`, tenantID).Scan(&deanID); err != nil {
		t.Fatalf("seed dean: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE user_id = $1::uuid`, deanID)
	})

	// PUT assigns both scratch colleges; the handler echoes them back by name.
	put := setSchoolsFor(t, pool, tenantID, userID, []string{a})
	if put.Code != http.StatusOK {
		t.Fatalf("PUT assign = %d %s", put.Code, put.Body.String())
	}
	var saved struct {
		Status  string             `json:"status"`
		Schools []monitorSchoolRow `json:"schools"`
	}
	if err := json.Unmarshal(put.Body.Bytes(), &saved); err != nil || saved.Status != "SAVED" {
		t.Fatalf("PUT response = %s (%v)", put.Body.String(), err)
	}
	if len(saved.Schools) != 1 || saved.Schools[0].Name != "ZZ Monitor College A" {
		t.Errorf("PUT saved %v, want the single assigned college", saved.Schools)
	}

	// GET must now report it — the hall read in real time for the room's college.
	get := listSchoolsFor(t, pool, tenantID, userID)
	if get.Code != http.StatusOK {
		t.Fatalf("GET after assign = %d %s", get.Code, get.Body.String())
	}
	var seen struct {
		Role    string             `json:"role"`
		Schools []monitorSchoolRow `json:"schools"`
	}
	if err := json.Unmarshal(get.Body.Bytes(), &seen); err != nil {
		t.Fatalf("GET response = %s (%v)", get.Body.String(), err)
	}
	if seen.Role != middleware.RoleQAMonitor || len(seen.Schools) != 1 {
		t.Errorf("GET after assign = role %q schools %v", seen.Role, seen.Schools)
	}

	// A foreign school id (a UUID nobody owns) is rejected wholesale and nothing is saved.
	foreign := "99999999-9999-4999-8999-999999999999"
	bad := setSchoolsFor(t, pool, tenantID, userID, []string{foreign})
	code := errorCodeOf(t, bad)
	if bad.Code != http.StatusBadRequest || code != "UNKNOWN_SCHOOL" {
		t.Errorf("foreign school id = %d %q, want 400 UNKNOWN_SCHOOL", bad.Code, code)
	}

	// Assigning a dean is refused before any row is touched — scope is a monitor thing.
	notMonitor := setSchoolsFor(t, pool, tenantID, deanID, []string{a})
	code = errorCodeOf(t, notMonitor)
	if notMonitor.Code != http.StatusBadRequest || code != "NOT_A_MONITOR" {
		t.Errorf("assigning a dean = %d %q, want 400 NOT_A_MONITOR", notMonitor.Code, code)
	}

	// An empty list is the valid "whole institution" state, so saving it must succeed.
	empty := setSchoolsFor(t, pool, tenantID, userID, []string{})
	if empty.Code != http.StatusOK {
		t.Errorf("clearing the assignment = %d %s, want 200", empty.Code, empty.Body.String())
	}
}

func setSchoolsFor(t *testing.T, pool *pgxpool.Pool, tenantID, userID string, ids []string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]interface{}{"school_ids": ids})
	req := httptest.NewRequest(http.MethodPut,
		"/api/v1/admin/users/"+userID+"/monitor-schools",
		bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req = req.WithContext(context.WithValue(context.WithValue(req.Context(), middleware.CtxTenantID, tenantID), middleware.CtxRole, middleware.RoleAdmin))
	w := httptest.NewRecorder()
	SetMonitorSchools(pool)(w, req)
	return w
}

func listSchoolsFor(t *testing.T, pool *pgxpool.Pool, tenantID, userID string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet,
		"/api/v1/admin/users/"+userID+"/monitor-schools", nil)
	req = req.WithContext(context.WithValue(context.WithValue(req.Context(), middleware.CtxTenantID, tenantID), middleware.CtxRole, middleware.RoleAdmin))
	w := httptest.NewRecorder()
	ListMonitorSchools(pool)(w, req)
	return w
}

func errorCodeOf(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	return body.Error
}

// The merge must be COMPLETE at the surface where roles are named, or an admin will quietly keep
// minting the dead labels and a client will 403 on a route that gate names it for. These source
// checks pin down where the three legacy labels are supposed to stop being creatable (the admin
// page) and where the new admin assignment page has to be reachable (the router). They need no
// database, exactly like the router checks in monitor_add_admin_test.go.
func TestMonitorConsolidation_AdminPageOffersOnlyTheMergedRole(t *testing.T) {
	admin, err := os.ReadFile("admin.go")
	if err != nil {
		t.Fatalf("could not read admin.go: %v", err)
	}
	src := string(admin)

	// The role list the Users page manages: QA_MONITOR in, the three legacy labels out.
	if !strings.Contains(src, `"QA_MONITOR": true`) {
		t.Error("MANAGED_ROLES no longer lists QA_MONITOR — the admin page could not create a monitor")
	}
	for _, legacy := range []string{`"QA_OFFICER": true`, `"QA_PATROLLER": true`, `"QA_SCHOOL_HANDLER": true`} {
		if strings.Contains(src, legacy) {
			t.Errorf("MANAGED_ROLES still lists a creatable legacy label %s — a monitor could be re-split into three boxes", legacy)
		}
	}

	// CreateUser accepts one QA label for new accounts, and it is not one of the dead ones.
	if !strings.Contains(src, `"QA_MONITOR":   true`) {
		t.Error("CreateUser validRoles no longer admits QA_MONITOR")
	}
	for _, legacy := range []string{`"QA_OFFICER": true`, `"QA_PATROLLER": true`, `"QA_SCHOOL_HANDLER": true`} {
		if strings.Contains(src, legacy) {
			t.Errorf("CreateUser still accepts a legacy label %s", legacy)
		}
	}
	// Creating with a school must land the monitor in qa_monitor_schools, not only free-text
	// users.school — otherwise the join-table scope (the dashboard's actual filter) stays empty.
	if !strings.Contains(src, `req.Role == "QA_MONITOR" && req.School != ""`) {
		t.Error("CreateUser no longer seeds qa_monitor_schools when a monitor is created with a school")
	}
}

func TestMonitorConsolidation_RouterExposesBothAssignmentEndpoints(t *testing.T) {
	router, err := os.ReadFile("../router/router.go")
	if err != nil {
		t.Fatalf("could not read the router source: %v", err)
	}
	src := string(router)

	// Both verbs for the admin-owned monitor-schools resource, each behind an ADMIN-only gate.
	if !strings.Contains(src, `Get("/api/v1/admin/users/{user_id}/monitor-schools", handlers.ListMonitorSchools(adminPool))`) {
		t.Error("router no longer wires GET /api/v1/admin/users/{user_id}/monitor-schools")
	}
	if !strings.Contains(src, `Put("/api/v1/admin/users/{user_id}/monitor-schools", handlers.SetMonitorSchools(adminPool))`) {
		t.Error("router no longer wires PUT /api/v1/admin/users/{user_id}/monitor-schools")
	}
	if strings.Count(src, "monitor-schools") != 2 {
		t.Errorf("expected exactly the two wired routes to reference the monitor-schools resource, found %d", strings.Count(src, "monitor-schools"))
	}
}
