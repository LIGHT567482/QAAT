package jobs

// DB-backed coverage of the two session-lifecycle sweeps (U-PANEL-MIGRATION §4.3):
//
//   - awaiting_session_claims resolves a check-in a student made before the register opened:
//     once the lecturer opens a register with that code, the queued claim is rejudged by the
//     shared verifier and lands as PRESENT with a ledger row; a code nobody ever opens stays
//     queued; a geofenced-out claim and one past the 7-day retention are closed as REJECTED.
//   - finalize_expired_sessions locks ACTIVE sessions whose window has run out (register =
//     checkin_window_end, coordinator = auto_close_time / T+auto_kill_minutes), finalises
//     ended-but-unfinalised sessions, and books the lecturer's contact hours that some
//     closing paths never wrote.
//
// Follows the repo's integration-test convention (the U-Panel register test) and SKIPS unless
// both DSNs are set — seed is a superuser connection planting/reading fixtures around RLS,
// data is the RLS-enforced qaat_app connection the sweeps write through:
//
//	GATEWAY_TEST_SEED_URL='postgres://postgres:pw@localhost:5439/qaat_verify?sslmode=disable' \
//	GATEWAY_TEST_DB_URL='postgres://qaat_app:pw@localhost:5439/qaat_verify?sslmode=disable' \
//	go test ./internal/jobs/ -run 'TestSessionSweeps' -v

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	swTenantID   = "10000000-0000-0000-0000-000000000001"
	swCourseID   = "SWEEP-IT-COURSE"
	swUnitID     = "SWEEP-IT-UNIT"
	swOfferingID = "20000000-0000-0000-0000-000000000002"
	swListID     = "30000000-0000-0000-0000-000000000003"

	swSessResolvable    = "40000000-0000-0000-0000-000000000001"
	swSessRegStale      = "40000000-0000-0000-0000-000000000002"
	swSessRegControl    = "40000000-0000-0000-0000-000000000003"
	swSessCoordStale    = "40000000-0000-0000-0000-000000000004"
	swSessCoordNoAuto   = "40000000-0000-0000-0000-000000000005"
	swSessCoordControl  = "40000000-0000-0000-0000-000000000006"
	swSessClosedUnfinal = "40000000-0000-0000-0000-000000000007"

	swLat     = 0.3476
	swLon     = 32.5825
	swRadius  = 1500
	swStudent = "S2020/SWP001"
)

func sweepPools(t *testing.T) (seed, data *pgxpool.Pool) {
	t.Helper()
	seedURL, dataURL := os.Getenv("GATEWAY_TEST_SEED_URL"), os.Getenv("GATEWAY_TEST_DB_URL")
	if seedURL == "" || dataURL == "" {
		t.Skip("set GATEWAY_TEST_SEED_URL and GATEWAY_TEST_DB_URL to run the sweep integration test")
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

func clearSweepDB(t *testing.T, ctx context.Context, seed *pgxpool.Pool) {
	t.Helper()
	if _, err := seed.Exec(ctx, `TRUNCATE tenants CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	// checkin_attempts carries no FK to tenants, so TRUNCATE tenants CASCADE leaves a previous
	// run's attempts behind.
	if _, err := seed.Exec(ctx, `DELETE FROM checkin_attempts`); err != nil {
		t.Fatalf("clear attempts: %v", err)
	}
}

// sweepSeedBase plants one tenant (wide session window, 60-min default register window, 120-min
// coordinator auto-kill) plus the course/unit/offering/list rows the session seeds need.
func sweepSeedBase(t *testing.T, ctx context.Context, seed *pgxpool.Pool) {
	t.Helper()
	stmts := []string{
		`INSERT INTO tenants (tenant_id, name, domain, rsa_key_id,
		     session_window_start, session_window_end, session_active_days, checkin_window_minutes, auto_kill_minutes)
		 VALUES ('` + swTenantID + `', 'Sweep Test', 'sweep.test', 'sweep-key',
		         '00:00'::time, '23:59'::time, ARRAY[1,2,3,4,5,6,7], 60, 120)`,
		`INSERT INTO courses (course_id, tenant_id, name)
		 VALUES ('` + swCourseID + `', '` + swTenantID + `', 'Sweep Test Course')`,
		`INSERT INTO course_units (unit_id, tenant_id, course_id, name, year, semester)
		 VALUES ('` + swUnitID + `', '` + swTenantID + `', '` + swCourseID + `', 'Sweep Test Unit', 2, 1)`,
		`INSERT INTO course_offerings (offering_id, tenant_id, course_id, session_type, study_year, semester)
		 VALUES ('` + swOfferingID + `', '` + swTenantID + `', '` + swCourseID + `', 'DAY', 2, 1)`,
		`INSERT INTO attendance_lists (list_id, tenant_id, offering_id, unit_id, title, room,
		     session_variant, year_label, semester, program)
		 VALUES ('` + swListID + `', '` + swTenantID + `', '` + swOfferingID + `',
		         '` + swUnitID + `', 'Sweep Test List', '', 'DAY', '2', '1', 'BSC')`,
	}
	for _, s := range stmts {
		if _, err := seed.Exec(ctx, s); err != nil {
			t.Fatalf("seed: %v\n%s", err, s)
		}
	}
}

func seedSession(t *testing.T, ctx context.Context, seed *pgxpool.Pool, cols, vals string) {
	t.Helper()
	if _, err := seed.Exec(ctx,
		`INSERT INTO sessions (tenant_id, coordinator_id, unit_id, session_date, session_status, finalized, `+cols+`)
		 VALUES ('`+swTenantID+`', 'sweep-coordinator', '`+swUnitID+`', CURRENT_DATE, 'ACTIVE', false, `+vals+`)`); err != nil {
		t.Fatalf("seed session: %v", err)
	}
}

func TestSessionSweeps_AwaitingResolution(t *testing.T) {
	seed, data := sweepPools(t)
	ctx := context.Background()
	clearSweepDB(t, ctx, seed)
	sweepSeedBase(t, ctx, seed)

	// One ACTIVE register (list-backed, geofenced at the hub's centre) whose window covers the
	// captured claims. The register has been open for 20 minutes and runs for two more hours.
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time, checkin_window_start, checkin_window_end,
		 list_id, latitude, longitude, radius_meters`,
		`'`+swSessResolvable+`', 'QW11',
		 now() - interval '20 minutes', now() - interval '20 minutes', now() + interval '2 hours',
		 '`+swListID+`'::uuid, `+fmt.Sprintf("%v", swLat)+`, `+fmt.Sprintf("%v", swLon)+`, `+fmt.Sprintf("%v", swRadius)+``)

	// Four queued claims (one student each):
	//   c1 — same coordinates, inside the window → resolves PRESENT with a ledger row.
	//   c2 — a code nobody has opened → stays awaiting for the next sweep.
	//   c3 — same code, kilometres away → resolved but REJECTED by the geofence.
	//   c4 — a code nobody has opened, older than the 7-day retention → closed REJECTED.
	attempts := []struct {
		id       string
		student  string
		code     string
		lat, lon float64
		when     string
	}{
		{`c1`, swStudent, `QW11`, swLat, swLon, `now() - interval '10 minutes'`},
		{`c2`, `S2020/SWP002`, `ZZ99`, swLat, swLon, `now() - interval '10 minutes'`},
		{`c3`, `S2020/SWP003`, `QW11`, 1.0, 33.0, `now() - interval '10 minutes'`},
		{`c4`, `S2020/SWP004`, `ZZ99`, swLat, swLon, `now() - interval '8 days'`},
	}
	for _, a := range attempts {
		if _, err := seed.Exec(ctx, `
			INSERT INTO checkin_attempts
			  (tenant_id, student_id, session_code, outcome, reason,
			   latitude, longitude, device_id, captured_offline, attempted_at, received_at, awaiting_session)
			VALUES ('`+swTenantID+`', `+fmt.Sprintf("'%s'", a.student)+`, `+fmt.Sprintf("'%s'", a.code)+`,
			        'PENDING', 'awaiting session', `+fmt.Sprintf("%v, %v", a.lat, a.lon)+`,
			        'hub-1', true, `+a.when+`, now(), true)`,
		); err != nil {
			t.Fatalf("seed attempt %s: %v", a.id, err)
		}
	}

	if err := resolveAwaitingSessionClaims(ctx, data, seed); err != nil {
		t.Fatalf("awaiting sweep: %v", err)
	}
	if err := resolveAwaitingSessionClaims(ctx, data, seed); err != nil {
		t.Fatalf("awaiting sweep (second pass): %v", err)
	}

	type row struct {
		outcome, reason string
		resolvedAt      *string
		sessionID       *string
	}
	readAttempt := func(studentID string) row {
		t.Helper()
		var got row
		if err := seed.QueryRow(ctx, `
			SELECT outcome, COALESCE(reason,''), resolved_at::text, session_id::text
			FROM checkin_attempts WHERE student_id = $1`, studentID).
			Scan(&got.outcome, &got.reason, &got.resolvedAt, &got.sessionID); err != nil {
			t.Fatalf("read attempt %s: %v", studentID, err)
		}
		return got
	}

	// c1: resolved PRESENT, tied to the register, and exactly one ledger row ever.
	c1 := readAttempt(swStudent)
	if c1.outcome != "PRESENT" || c1.resolvedAt == nil || c1.sessionID == nil || *c1.sessionID != swSessResolvable {
		t.Fatalf("c1 = outcome:%s session:%v resolved, want PRESENT against %s",
			c1.outcome, strPtr(c1.sessionID), swSessResolvable)
	}
	if got := *mustScanInt(t, ctx, seed, `SELECT COUNT(*) FROM attendance_logs
		WHERE session_id = '`+swSessResolvable+`'::uuid AND student_id = '`+swStudent+`'`); got != 1 {
		t.Fatalf("ledger rows = %d, want exactly 1 (one PRESENT, never two)", got)
	}

	// c2: still awaiting — the register for ZZ99 never opened.
	if c2 := readAttempt(`S2020/SWP002`); c2.outcome != "PENDING" || c2.resolvedAt != nil {
		t.Fatalf("c2 finalised early: %s/%v", c2.outcome, c2.resolvedAt)
	}

	// c3: the code resolved, the geofence did not — REJECTED and stamped.
	if c3 := readAttempt(`S2020/SWP003`); c3.outcome != "REJECTED" ||
		c3.resolvedAt == nil || !strings.Contains(c3.reason, "location") {
		t.Fatalf("c3 = %s/%q, want REJECTED outside class location", c3.outcome, c3.reason)
	}

	// c4: past retention, still unopenable — closed rather than queued forever.
	if c4 := readAttempt(`S2020/SWP004`); c4.outcome != "REJECTED" ||
		c4.resolvedAt == nil || !strings.Contains(c4.reason, "no register") {
		t.Fatalf("c4 = %s/%q, want REJECTED by retention", c4.outcome, c4.reason)
	}

	var staleCount int
	_ = seed.QueryRow(ctx, `SELECT COUNT(*) FROM checkin_attempts WHERE awaiting_session = true`).Scan(&staleCount)
	if staleCount != 1 {
		t.Fatalf("awaiting rows left = %d, want 1 (only the still-unopenable c2)", staleCount)
	}
}

func TestSessionSweeps_Expiry(t *testing.T) {
	seed, _ := sweepPools(t)
	ctx := context.Background()
	clearSweepDB(t, ctx, seed)
	sweepSeedBase(t, ctx, seed)

	// Register (list-backed) sessions — expired and live control.
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time, checkin_window_start, checkin_window_end, list_id, latitude, longitude, radius_meters`,
		`'`+swSessRegStale+`', 'QW22',
		 now() - interval '35 minutes', now() - interval '35 minutes', now() - interval '5 minutes',
		 '`+swListID+`'::uuid, `+fmt.Sprintf("%v, %v, %v", swLat, swLon, swRadius)+``)
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time, checkin_window_start, checkin_window_end, list_id`,
		`'`+swSessRegControl+`', 'QW23',
		 now() - interval '5 minutes', now() - interval '5 minutes', now() + interval '25 minutes',
		 '`+swListID+`'::uuid`)

	// Coordinator sessions (no list): auto-close time expired, T+auto_kill fallback expired,
	// and a live control.
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time, auto_close_time`,
		`'`+swSessCoordStale+`', 'QW24',
		 now() - interval '185 minutes', now() - interval '5 minutes'`)
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time`,
		`'`+swSessCoordNoAuto+`', 'QW25', now() - interval '250 minutes'`)
	seedSession(t, ctx, seed,
		`session_id, session_code, gate_open_time, auto_close_time`,
		`'`+swSessCoordControl+`', 'QW26',
		 now() - interval '10 minutes', now() + interval '30 minutes'`)

	// Ended but never finalised.
	if _, err := seed.Exec(ctx, `
		INSERT INTO sessions (session_id, tenant_id, coordinator_id, unit_id, session_date,
		                      session_status, sync_status, audit_flags, gate_open_time, gate_close_time)
		VALUES ('`+swSessClosedUnfinal+`', '`+swTenantID+`', 'sweep-coordinator', '`+swUnitID+`', CURRENT_DATE,
		        'CLOSED', 'PENDING', '{}', now() - interval '60 minutes', now() - interval '30 minutes')`); err != nil {
		t.Fatalf("seed closed-unfinalised session: %v", err)
	}

	// The stale register's lecturer-attendance row is still open — the gap the sweep must fill.
	if _, err := seed.Exec(ctx, `
		INSERT INTO lecturer_attendance_logs
		  (tenant_id, session_id, lecturer_id, gate_open_time, unit_id, session_date)
		VALUES ('`+swTenantID+`', '`+swSessRegStale+`'::uuid, 'sweep-lecturer',
		       now() - interval '35 minutes', '`+swUnitID+`', CURRENT_DATE)`); err != nil {
		t.Fatalf("seed lecturer log: %v", err)
	}

	if err := finalizeExpiredSessions(ctx, seed); err != nil {
		t.Fatalf("expiry sweep: %v", err)
	}
	if err := finalizeExpiredSessions(ctx, seed); err != nil {
		t.Fatalf("expiry sweep (second pass / idempotence): %v", err)
	}

	type row struct {
		status    string
		finalized bool
		closeMin  float64 // gate_close_time - gate_open_time, in minutes
	}
	assertSession := func(id string, want row) {
		t.Helper()
		var got row
		if err := seed.QueryRow(ctx, `
			SELECT session_status::text, finalized,
			       EXTRACT(EPOCH FROM (COALESCE(gate_close_time, now()) - gate_open_time)) / 60.0
			FROM sessions WHERE session_id = $1::uuid`, id).Scan(&got.status, &got.finalized, &got.closeMin); err != nil {
			t.Fatalf("read session %s: %v", id, err)
		}
		if got.status != want.status || got.finalized != want.finalized {
			t.Fatalf("session %s = %s/finalized:%v, want %s/finalized:%v",
				id, got.status, got.finalized, want.status, want.finalized)
		}
		if want.closeMin >= 0 && abs(got.closeMin-want.closeMin) > 1 {
			t.Fatalf("session %s window = %.2f min, want %.2f", id, got.closeMin, want.closeMin)
		}
	}

	assertSession(swSessRegStale, row{"AUTO_CLOSED", true, 30})     // end(now-5) − open(now-35)
	assertSession(swSessRegControl, row{"ACTIVE", false, -1})       // still live
	assertSession(swSessCoordStale, row{"AUTO_CLOSED", true, 180})  // open(now-185) + auto_close(now-5)... wait, checked below
	assertSession(swSessCoordNoAuto, row{"AUTO_CLOSED", true, 120}) // open(now-250) + auto_kill 120
	assertSession(swSessCoordControl, row{"ACTIVE", false, -1})     // still live
	assertSession(swSessClosedUnfinal, row{"CLOSED", true, -1})     // finalised, unchanged otherwise

	var lecturerMinutes *float64
	var endedAt *string
	if err := seed.QueryRow(ctx, `
		SELECT contact_hours * 60, lecturer_ended_at::text
		FROM lecturer_attendance_logs WHERE session_id = $1::uuid`, swSessRegStale).Scan(
		&lecturerMinutes, &endedAt); err != nil {
		t.Fatalf("read lecturer log: %v", err)
	}
	if endedAt == nil || lecturerMinutes == nil || abs(*lecturerMinutes-30) > 1 {
		t.Fatalf("gap-fill did not book hours: contact=%.2fmin ended=%v",
			floatP(lecturerMinutes), endedAt)
	}
}

func mustScanInt(t *testing.T, ctx context.Context, seed *pgxpool.Pool, q string) *int {
	t.Helper()
	var n int
	if err := seed.QueryRow(ctx, q).Scan(&n); err != nil {
		t.Fatalf("scan int: %v", err)
	}
	return &n
}

func strPtr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func floatP(p *float64) float64 {
	if p == nil {
		return -1
	}
	return *p
}
func abs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}
