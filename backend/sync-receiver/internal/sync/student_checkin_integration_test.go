package sync

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// recvTestDBURL runs the receiver's verifier path against Postgres, skipped when
// unset. The database must already have all migrations applied (see the migrate
// command in api-gateway). RECEIVER_TEST_SEED_URL is the owner/superuser
// connection used to plant fixture rows around the RLS-enforced data plane.
func recvTestDBURL(t *testing.T) (dataURL, seedURL string) {
	t.Helper()
	dataURL = os.Getenv("RECEIVER_TEST_DB_URL")
	seedURL = os.Getenv("RECEIVER_TEST_SEED_URL")
	if dataURL == "" {
		t.Skip("RECEIVER_TEST_DB_URL not set; skipping receiver integration test")
	}
	if seedURL == "" {
		seedURL = dataURL
	}
	return dataURL, seedURL
}

const (
	fxTenant  = "11111111-1111-1111-1111-111111111111"
	fxCourse  = "C1"
	fxUnit    = "U1"
	fxSession = "22222222-2222-2222-2222-222222222222"
)

func seedReceiverFixture(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	stmts := []string{
		`INSERT INTO tenants (tenant_id, name, domain, student_hash_key, rsa_key_id)
		 VALUES ('` + fxTenant + `', 'ACME Test', 'acme.test', 'k', 'seed-key-1')`,
		`INSERT INTO courses (course_id, tenant_id, name)
		 VALUES ('` + fxCourse + `', '` + fxTenant + `', 'Constitutional Law')`,
		`INSERT INTO course_units (unit_id, tenant_id, course_id, name, year, semester)
		 VALUES ('` + fxUnit + `', '` + fxTenant + `', '` + fxCourse + `', 'Legal Methods', 2, 1)
		 ON CONFLICT (unit_id) DO NOTHING`,
		`INSERT INTO sessions
		  (session_id, tenant_id, coordinator_id, unit_id, session_date, session_status,
		   checkin_window_start, checkin_window_end, latitude, longitude, radius_meters,
		   session_code, delivery_mode, unscheduled, room_is_provision, finalized)
		 VALUES
		  ('` + fxSession + `', '` + fxTenant + `', 'coord-1', '` + fxUnit + `',
		   CURRENT_DATE, 'ACTIVE',
		   '2026-09-11T09:00:00Z', '2026-09-11T11:00:00Z',
		   0.3120, 32.5808, 1500, 'AB1Z',
		   'ONLINE', false, false, false)
		 ON CONFLICT (session_id) DO NOTHING`,
	}
	for _, s := range stmts {
		if _, err := pool.Exec(ctx, s); err != nil {
			t.Fatalf("seed: %v\n%s", err, s)
		}
	}
}

func TestProcessStudentAttemptsEndToEnd(t *testing.T) {
	dataURL, seedURL := recvTestDBURL(t)
	ctx := context.Background()

	seedPool, err := pgxpool.New(ctx, seedURL)
	if err != nil {
		t.Fatalf("seed pool: %v", err)
	}
	defer seedPool.Close()
	if _, err := seedPool.Exec(ctx, `TRUNCATE tenants CASCADE`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	seedReceiverFixture(t, ctx, seedPool)

	pool, err := pgxpool.New(ctx, dataURL)
	if err != nil {
		t.Fatalf("data pool: %v", err)
	}
	defer pool.Close()

	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer conn.Release()
	// Mirrors the real receiver: app.current_tenant set, RLS FORCEing active.
	if _, err := conn.Exec(ctx, `SELECT set_config('app.current_tenant', $1, false)`, fxTenant); err != nil {
		t.Fatalf("set tenant: %v", err)
	}

	id := func(n int) string {
		return "33333333-3333-3333-3333-3333333333" + string(rune('0'+n)) + string(rune('0'+n))
	}
	// Six records: accept, duplicate, window-reject, geo-reject, by-code accept,
	// pending (code that matches nothing yet).
	records := []studentRecord{
		{LogID: id(1), SessionID: fxSession, StudentIDHash: "H1", SequenceNumber: 1,
			CheckinTimestamp: "2026-09-11T09:30:00Z", EntryMethod: "QR_SCAN",
			Latitude: 0.3121, Longitude: 32.5809, GPSAccuracyMeters: 8},
		{LogID: id(2), SessionID: fxSession, StudentIDHash: "H1", SequenceNumber: 1,
			CheckinTimestamp: "2026-09-11T09:30:05Z", EntryMethod: "QR_SCAN",
			Latitude: 0.3121, Longitude: 32.5809},
		{LogID: id(3), SessionID: fxSession, StudentIDHash: "H2", SequenceNumber: 2,
			CheckinTimestamp: "2026-09-11T08:00:00Z", EntryMethod: "QR_SCAN",
			Latitude: 0.3121, Longitude: 32.5809},
		{LogID: id(4), SessionID: fxSession, StudentIDHash: "H3", SequenceNumber: 3,
			CheckinTimestamp: "2026-09-11T09:40:00Z", EntryMethod: "QR_SCAN",
			Latitude: 0.3500, Longitude: 32.5808},
		{LogID: id(5), StudentIDHash: "H4", SequenceNumber: 4,
			CheckinTimestamp: "2026-09-11T09:45:00Z", SessionCode: "AB1Z",
			EntryMethod: "QR_SCAN", Latitude: 0.3121, Longitude: 32.5809},
{LogID: id(6), StudentIDHash: "H5", SequenceNumber: 5,
			CheckinTimestamp: "2026-09-11T09:50:00Z", SessionCode: "ZZ99",
			EntryMethod: "QR_SCAN", Latitude: 0.3121, Longitude: 32.5809},
	}
	hashToReg := map[string]string{"H1": "S2019/001", "H2": "S2019/002", "H3": "S2019/003", "H4": "S2019/004", "H5": "S2019/005"}
	// The lecturer DID scan today's gate → the gate telemetry never fires for the
	// by-session records. The two empty-session claims still carry the legacy +1
	// each (verified[""] is false), matching the old counter exactly.
	gated := map[string]bool{fxSession: true}

	written, duplicates, rejected, err := processStudentAttempts(ctx, conn, fxTenant, "coord-1", records, hashToReg, gated)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if written != 2 || duplicates != 1 {
		t.Fatalf("written=%d (want 2) dup=%d (want 1)", written, duplicates)
	}
	// rejected = 2 engine rejects (window, geo) + 2 gate telemetry (the two
	// empty-session claims) = 4.
	if rejected != 4 {
		t.Fatalf("rejected=%d (want 4: 2 engine + 2 gate telemetry)", rejected)
	}

	var ledgerCount int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM attendance_logs`).Scan(&ledgerCount); err != nil {
		t.Fatalf("ledger count: %v", err)
	}
	if ledgerCount != 2 {
		t.Fatalf("attendance_logs has %d rows, want 2 (only H1 and the by-code H4 accepted)", ledgerCount)
	}

	var (
		studentID string
		dist      int
		entry     string
		offline   bool
	)
	if err := conn.QueryRow(ctx, `
		SELECT student_id, distance_meters, entry_method::text, captured_offline
		FROM attendance_logs WHERE student_id IN ('S2019/001','S2019/004')
		ORDER BY student_id LIMIT 1`).Scan(&studentID, &dist, &entry, &offline); err != nil {
		t.Fatalf("ledger row: %v", err)
	}
	if dist < 1 || dist > 200 || entry != "QR_SCAN" || offline {
		t.Fatalf("ledger row odd: student=%s dist=%d entry=%s offline=%v", studentID, dist, entry, offline)
	}

	// Every attempt is preserved with its verdict and reason.
	wantAttempt := map[int]struct{ outcome, reason string }{
		1: {"PRESENT", ""},
		2: {"DUPLICATE", ""},
		3: {"REJECTED", "outside session time"},
		4: {"REJECTED", "outside class location"},
		5: {"PRESENT", ""},
		6: {"PENDING", ""}, // awaiting_session=true, resolved later by the sweep
	}
	for n, want := range wantAttempt {
		var outcome, reason string
		if err := conn.QueryRow(ctx, `
			SELECT outcome, reason FROM checkin_attempts WHERE attempt_id::text = $1`, id(n)).Scan(&outcome, &reason); err != nil {
			t.Fatalf("attempt %d: %v", n, err)
		}
		if outcome != want.outcome || reason != want.reason {
			t.Fatalf("attempt %d: outcome=%q reason=%q (want %q/%q)", n, outcome, reason, want.outcome, want.reason)
		}
	}

	var awaiting bool
	if err := conn.QueryRow(ctx, `SELECT awaiting_session FROM checkin_attempts WHERE attempt_id::text = $1`, id(6)).Scan(&awaiting); err != nil {
		t.Fatalf("wait: %v", err)
	}
	if !awaiting {
		t.Fatal("unresolved code claim must be parked awaiting_session=true for the sweep")
	}

	// The by-code H4 claim welded the resolved session onto its attempt row.
	var resolvedSession string
	if err := conn.QueryRow(ctx, `SELECT session_id::text FROM checkin_attempts WHERE attempt_id::text = $1`, id(5)).Scan(&resolvedSession); err != nil {
		t.Fatalf("resolved: %v", err)
	}
	if resolvedSession != fxSession {
		t.Fatalf("by-code attempt resolved to %s, want %s", resolvedSession, fxSession)
	}
}