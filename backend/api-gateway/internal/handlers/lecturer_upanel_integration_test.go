package handlers

// DB-backed end-to-end coverage of the U-Panel register flow (migration 109):
//
//	a lecturer opens their own attendance list → a live hub check-in judged by the shared
//	verifier is accepted → the second tap is a duplicate → a wrong code is refused and
//	kept → closing books the contact hours and finalises the session for good.
//
// It follows the repo's integration-test convention (the sync-receiver's student_checkin
// test and the sessions race test) and SKIPS unless the two DSNs are set — seed is a
// superuser connection used to plant/read fixture rows around RLS, data is the
// RLS-enforced qaat_app connection the handlers themselves use:
//
//	GATEWAY_TEST_SEED_URL='postgres://postgres:pw@localhost:5439/qaat_verify?sslmode=disable' \
//	GATEWAY_TEST_DB_URL='postgres://qaat_app:pw@localhost:5439/qaat_verify?sslmode=disable' \
//	go test ./internal/handlers/ -run TestUPanelRegisterFlow -v

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
)

const (
	upTenantID   = "a0000000-0000-0000-0000-000000000001"
	upCourseID   = "UPANEL-IT-TEST-COURSE"
	upUnitID     = "UPANEL-IT-TEST-UNIT"
	upOfferingID = "b0000000-0000-0000-0000-000000000002"
	upListID     = "c0000000-0000-0000-0000-000000000003"
	upLecUser    = "d0000000-0000-0000-0000-000000000002"
	upLecturerID = "e0000000-0000-0000-0000-000000000001"
)

const (
	upLat     = 0.3476
	upLon     = 32.5825
	upStudent = "S2020/UP001"
)

// upanelPools returns the superuser seed pool and the RLS-enforced qaat_app data pool.
func upanelPools(t *testing.T) (seed, data *pgxpool.Pool) {
	t.Helper()
	seedURL := os.Getenv("GATEWAY_TEST_SEED_URL")
	dataURL := os.Getenv("GATEWAY_TEST_DB_URL")
	if seedURL == "" || dataURL == "" {
		t.Skip("set GATEWAY_TEST_SEED_URL and GATEWAY_TEST_DB_URL to run the register integration test")
	}
	ctx := context.Background()
	s, err := pgxpool.New(ctx, seedURL)
	if err != nil || s.Ping(ctx) != nil {
		t.Skipf("seed database unavailable: %v", err)
	}
	t.Cleanup(s.Close)
	d, err := pgxpool.New(ctx, dataURL)
	if err != nil || d.Ping(ctx) != nil {
		t.Skipf("data database unavailable: %v", err)
	}
	t.Cleanup(d.Close)
	return s, d
}

// seedUPanel plants one tenant with a widened session window (00:00–23:59 every day, so the
// window gate never blocks the test), one (offering, unit) cohort, its attendance list owned by
// a lecturer, and two ACTIVE students.
func seedUPanel(t *testing.T, ctx context.Context, seed *pgxpool.Pool) {
	t.Helper()
	stmts := []string{
		`INSERT INTO tenants (tenant_id, name, domain, rsa_key_id,
		     session_window_start, session_window_end, session_active_days, checkin_window_minutes)
		 VALUES ('` + upTenantID + `', 'U-Panel Test', 'upanel.test', 'seed-key-up',
		         '00:00'::time, '23:59'::time, ARRAY[1,2,3,4,5,6,7], 60)`,
		`INSERT INTO courses (course_id, tenant_id, name)
		 VALUES ('` + upCourseID + `', '` + upTenantID + `', 'U-Panel Test Course')`,
		`INSERT INTO course_units (unit_id, tenant_id, course_id, name, year, semester)
		 VALUES ('` + upUnitID + `', '` + upTenantID + `', '` + upCourseID + `', 'U-Panel Test Unit', 2, 1)`,
		`INSERT INTO course_offerings (offering_id, tenant_id, course_id, session_type, study_year, semester)
		 VALUES ('` + upOfferingID + `', '` + upTenantID + `', '` + upCourseID + `', 'DAY', 2, 1)`,
		`INSERT INTO users (user_id, tenant_id, email, password_hash, role, full_name, is_active)
		 VALUES ('` + upLecUser + `', '` + upTenantID + `', 'up.lecturer@upanel.test',
		         'x', 'LECTURER', 'U-Panel Lecturer', true)`,
		`INSERT INTO lecturers (lecturer_id, tenant_id, full_name, email, user_id)
		 VALUES ('` + upLecturerID + `', '` + upTenantID + `', 'U-Panel Lecturer',
		         'up.lecturer@upanel.test', '` + upLecUser + `'::uuid)`,
		`INSERT INTO attendance_lists (list_id, tenant_id, offering_id, unit_id, title, lecturer_id)
		 VALUES ('` + upListID + `', '` + upTenantID + `', '` + upOfferingID + `', '` + upUnitID + `',
		         'U-Panel Test List', '` + upLecturerID + `'::uuid)`,
		`INSERT INTO students_extended (student_id, tenant_id, full_name, email, course_id, academic_year, offering_id)
		 VALUES ('` + upStudent + `', '` + upTenantID + `', 'U-Panel Student One', 'one@upanel.test',
		         '` + upCourseID + `', '2024/2025', '` + upOfferingID + `'::uuid)`,
		`INSERT INTO students_extended (student_id, tenant_id, full_name, email, course_id, academic_year, offering_id)
		 VALUES ('S2020/UP002', '` + upTenantID + `', 'U-Panel Student Two', 'two@upanel.test',
		         '` + upCourseID + `', '2024/2025', '` + upOfferingID + `'::uuid)`,
	}
	for _, s := range stmts {
		if _, err := seed.Exec(ctx, s); err != nil {
			t.Fatalf("seed: %v\n%s", err, s)
		}
	}
}

// connID marks a request as the named user in the given role, as the JWT middleware would.
func connID(userID, role string) func(*http.Request) *http.Request {
	return func(r *http.Request) *http.Request {
		c := context.WithValue(r.Context(), middleware.CtxTenantID, upTenantID)
		c = context.WithValue(c, middleware.CtxUserID, userID)
		c = context.WithValue(c, middleware.CtxRole, role)
		return r.WithContext(c)
	}
}

// withRouteParam injects a chi path parameter (URLParam) as the router middleware would.
func withRouteParam(r *http.Request, key, value string) *http.Request {
	rctx := chi.NewRouteContext()
	rctx.URLParams.Keys = []string{key}
	rctx.URLParams.Values = []string{value}
	return r.WithContext(context.WithValue(r.Context(), chi.RouteCtxKey, rctx))
}

// perform runs one handler and decodes its JSON response into out (nil to skip).
func perform(t *testing.T, h http.HandlerFunc, method, path, body string,
	route map[string]string, auth func(*http.Request) *http.Request, out interface{}) int {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth != nil {
		req = auth(req)
	}
	if route != nil {
		for k, v := range route {
			req = withRouteParam(req, k, v)
		}
	}
	rec := httptest.NewRecorder()
	h(rec, req)
	if rec.Code >= 500 {
		t.Logf("perform %s %s -> %d: %s", method, path, rec.Code, rec.Body.String())
	}
	if out != nil {
		_ = json.Unmarshal(rec.Body.Bytes(), out)
	}
	return rec.Code
}

func TestUPanelRegisterFlow(t *testing.T) {
	seed, data := upanelPools(t)
	ctx := context.Background()
	if _, err := seed.Exec(ctx, `TRUNCATE tenants CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	// checkin_attempts carries no FK to tenants, so TRUNCATE tenants CASCADE leaves a previous
	// run's kept refusals behind — and the wrong-code assertion counts exactly.
	if _, err := seed.Exec(ctx, `DELETE FROM checkin_attempts`); err != nil {
		t.Fatalf("clear attempts: %v", err)
	}
	seedUPanel(t, ctx, seed)

	openHandler := LecturerOpenSession(data, seed)
	targetHandler := HubCheckin(data, seed)
	closeHandler := LecturerCloseSession(data, seed)
	lecturerAuth := connID(upLecUser, middleware.RoleLecturer)

	// ── 1. The lecturer opens their own list. Role LECTURER: no privileged-opener bypass —
	//    the right to the roster is proven through lecturers.user_id → lecturers → the list's
	//    lecturer_id.
	var open struct {
		SessionID   string `json:"session_id"`
		ListID      string `json:"list_id"`
		UnitID      string `json:"unit_id"`
		SessionCode string `json:"session_code"`
		Enrolled    int    `json:"enrolled"`
		AlreadyOpen bool   `json:"already_open"`
	}
	openBody := `{"list_id":"` + upListID + `","latitude":` + fnum(upLat) +
		`,"longitude":` + fnum(upLon) + `}`
	if code := perform(t, openHandler, http.MethodPost, "/api/v1/lecturer/sessions/open",
		openBody, nil, lecturerAuth, &open); code != http.StatusCreated {
		t.Fatalf("open returned %d, want 201", code)
	}
	if len(open.SessionCode) != 4 || open.SessionID == "" || open.AlreadyOpen {
		t.Fatalf("open response odd: %+v", open)
	}
	if open.Enrolled != 2 {
		t.Fatalf("enrolled=%d, want 2 (two ACTIVE students on the offering)", open.Enrolled)
	}

	// The session lands ACTIVE, tied to the list, in-person, and the register's lecturer took
	// the session as their own attendance from the moment it opened.
	var (
		status, sessionLecturer, delivery, coordinatorID string
		listID, offerID, finalized                       string
		scanned                                          *string
	)
	if err := seed.QueryRow(ctx, `
		SELECT session_status::text, COALESCE(lecturer_id::text,''), delivery_mode::text,
		       coordinator_id, list_id::text, offering_id::text, finalized::text
		FROM sessions WHERE session_id = $1::uuid`, open.SessionID).Scan(
		&status, &sessionLecturer, &delivery, &coordinatorID, &listID, &offerID, &finalized); err != nil {
		t.Fatalf("read session: %v", err)
	}
	if status != "ACTIVE" || listID != upListID || offerID != upOfferingID ||
		delivery != "IN_PERSON" || coordinatorID != upLecUser || finalized != "false" {
		t.Fatalf("session row odd: status=%s list=%s offering=%s delivery=%s coord=%s finalized=%s",
			status, listID, offerID, delivery, coordinatorID, finalized)
	}
	if sessionLecturer != upLecturerID {
		t.Fatalf("session lecturer = %s, want %s (the list's lecturer)", sessionLecturer, upLecturerID)
	}
	if err := seed.QueryRow(ctx, `
		SELECT lecturer_scanned_at::text FROM lecturer_attendance_logs
		WHERE session_id = $1::uuid`, open.SessionID).Scan(&scanned); err != nil {
		t.Fatalf("lecturer attendance stamped at open: %v", err)
	}
	if scanned == nil || *scanned == "" {
		t.Fatal("lecturer_scanned_at must be set the moment the register opens")
	}

	// ── 2. Opening the same list again is a no-op: same session, same code, already_open.
	var again struct {
		SessionID   string `json:"session_id"`
		SessionCode string `json:"session_code"`
		AlreadyOpen bool   `json:"already_open"`
	}
	if code := perform(t, openHandler, http.MethodPost, "/api/v1/lecturer/sessions/open",
		openBody, nil, lecturerAuth, &again); code != http.StatusOK {
		t.Fatalf("second open returned %d, want 200 (idempotent)", code)
	}
	if !again.AlreadyOpen || again.SessionID != open.SessionID || again.SessionCode != open.SessionCode {
		t.Fatalf("idempotent open did not return the live register: %+v (expect session %s)", again, open.SessionID)
	}

	// ── 3. A live hub check-in under the spoken code is PRESENT, with a ledger record.
	var hit struct {
		Status   string `json:"status"`
		LogID    string `json:"log_id"`
		ListID   string `json:"list_id"`
		Distance int    `json:"distance_meters"`
	}
	checkin := `{"session_code":"` + open.SessionCode + `","student_id":"` + upStudent +
		`","latitude":` + fnum(upLat) + `,"longitude":` + fnum(upLon) +
		`,"gps_accuracy_meters":8,"device_id":"hub-1"}`
	if code := perform(t, targetHandler, http.MethodPost, "/api/v1/attendance/hub-checkin",
		checkin, nil, nil, &hit); code != http.StatusOK || hit.Status != "PRESENT" {
		t.Fatalf("check-in returned %d %+v, want 200 PRESENT", code, hit)
	}
	if hit.ListID != upListID || hit.LogID == "" {
		t.Fatalf("check-in response lacks the list/ledger bindings: %+v", hit)
	}

	var entryMethod, logStudent string
	var seq int
	if err := seed.QueryRow(ctx, `
		SELECT entry_method::text, student_id, sequence_number
		FROM attendance_logs WHERE log_id = $1::uuid`, hit.LogID).Scan(
		&entryMethod, &logStudent, &seq); err != nil {
		t.Fatalf("read ledger row: %v", err)
	}
	if entryMethod != "HUB_VERIFIED" || logStudent != upStudent || seq != 1 {
		t.Fatalf("ledger row odd: entry=%s student=%s seq=%d", entryMethod, logStudent, seq)
	}

	// ── 4. The second tap for the same student is DUPLICATE — and kept as a record.
	var dup struct {
		Status string `json:"status"`
	}
	if code := perform(t, targetHandler, http.MethodPost, "/api/v1/attendance/hub-checkin",
		checkin, nil, nil, &dup); code != http.StatusOK || dup.Status != "DUPLICATE" {
		t.Fatalf("duplicate tap returned %d %+v, want 200 DUPLICATE", code, dup)
	}

	// ── 5. A code that matches no open register is refused AND KEPT as evidence.
	var bad struct {
		Status string `json:"status"`
		Reason string `json:"reason"`
	}
	badCheckin := `{"session_code":"ZZ99","student_id":"S2020/UP003","latitude":` + fnum(upLat) +
		`,"longitude":` + fnum(upLon) + `,"device_id":"hub-1"}`
	if code := perform(t, targetHandler, http.MethodPost, "/api/v1/attendance/hub-checkin",
		badCheckin, nil, nil, &bad); code != http.StatusUnprocessableEntity || bad.Status != "REJECTED" {
		t.Fatalf("wrong code returned %d %+v, want 422 REJECTED", code, bad)
	}
	var refusedCount int
	if err := seed.QueryRow(ctx, `
		SELECT COUNT(*) FROM checkin_attempts
		WHERE student_id = 'S2020/UP003' AND outcome = 'REJECTED'
		  AND reason ILIKE '%no open register%'`).Scan(&refusedCount); err != nil {
		t.Fatalf("read refused attempt: %v", err)
	}
	if refusedCount != 1 {
		t.Fatalf("wrong code produced %d kept refusals, want exactly 1", refusedCount)
	}

	// ── 6. Closing books the contact hours and finalises the session.
	var closeResp map[string]interface{}
	closeRoute := map[string]string{"session_id": open.SessionID}
	if code := perform(t, closeHandler, http.MethodPost,
		"/api/v1/lecturer/sessions/"+open.SessionID+"/close", "", closeRoute, lecturerAuth, &closeResp); code != http.StatusOK {
		t.Fatalf("close returned %d, want 200", code)
	}
	if closeResp["status"] != "CLOSED" {
		t.Fatalf("close response: %+v", closeResp)
	}
	var closedStatus string
	var contactHours *float64
	var endedAt *string
	if err := seed.QueryRow(ctx, `
		SELECT s.session_status::text, lal.contact_hours, lal.lecturer_ended_at::text
		FROM sessions s
		JOIN lecturer_attendance_logs lal ON lal.session_id = s.session_id
		WHERE s.session_id = $1::uuid`, open.SessionID).Scan(
		&closedStatus, &contactHours, &endedAt); err != nil {
		t.Fatalf("read closed session: %v", err)
	}
	if closedStatus != "CLOSED" {
		t.Fatalf("session status after close = %s, want CLOSED", closedStatus)
	}
	if contactHours == nil || endedAt == nil {
		t.Fatalf("close did not book contact hours (contact_hours=%v lecturer_ended_at=%v)",
			contactHours, endedAt)
	}

	// ── 7. Closing the same register again finds nothing open.
	var againClose map[string]interface{}
	if code := perform(t, closeHandler, http.MethodPost,
		"/api/v1/lecturer/sessions/"+open.SessionID+"/close", "", closeRoute, lecturerAuth, &againClose); code != http.StatusNotFound {
		t.Fatalf("second close returned %d, want 404", code)
	}
}

// fnum renders a float as JSON (no exponent).
func fnum(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}
