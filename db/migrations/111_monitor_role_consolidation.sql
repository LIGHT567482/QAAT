-- 111: One QA monitor role — the body.
--
-- Migration 110 added the QA_MONITOR enum label (alone, because using a freshly added value in the
-- same transaction as ADD VALUE is refused with SQLSTATE 55P04). This migration does the work.
--
-- QA has been three roles that were really one job: the OFFICER who ran the round, the PATROLLER
-- who walked it, and the SCHOOL HANDLER who filed what the walk found. Three accounts, three
-- dashboards, three sets of scoping rules, and an admin page with three boxes to tick for people
-- who all carry out the same patrol.
--
-- WHAT ARRIVES HERE:
--   users.role   — every QA_OFFICER / QA_PATROLLER / QA_SCHOOL_HANDLER row becomes QA_MONITOR.
--                  The enum keeps the old labels — the gateway translates a JWT minted under a
--                  legacy label onto QA_MONITOR for the deploy window, so a monitor who signed in
--                  before the rename is not locked out — but no live account carries one any more.
--   qa_monitor_schools — the join table a monitor's scoped view reads from (dashboards, reports,
--                  QA broadcasts). Migration 075's user_schools carried this for the school
--                  handler; the new table is written by the admin Users page and seeded here from
--                  the old table plus users.school.
--
-- SCOPE AFTER THE MERGE. A monitor with assigned schools is bounded by them; one with none is
-- given the whole institution (the officer's old remit) rather than an empty page. QA patrol is
-- institution-wide work, so an unassigned monitor must still be able to do it, while an assigned
-- monitor's dashboards and reports are exactly their schools.

-- ─── 1. A monitor's schools (0..n) ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS qa_monitor_schools (
    user_id    UUID NOT NULL REFERENCES users(user_id)     ON DELETE CASCADE,
    tenant_id  UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    school_id  UUID NOT NULL REFERENCES schools(school_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, user_id, school_id)
);
CREATE INDEX IF NOT EXISTS idx_qa_monitor_schools_tenant_user
    ON qa_monitor_schools (tenant_id, user_id);

ALTER TABLE qa_monitor_schools ENABLE ROW LEVEL SECURITY;
ALTER TABLE qa_monitor_schools FORCE  ROW LEVEL SECURITY;
-- DROP-then-CREATE: CREATE POLICY has no IF NOT EXISTS, so a hand-built database would fail
-- here and leave the migration half-applied.
DROP POLICY IF EXISTS "tenant_isolation" ON qa_monitor_schools;
CREATE POLICY "tenant_isolation" ON qa_monitor_schools
    FOR ALL USING (tenant_id = current_setting('app.current_tenant', true)::uuid);
GRANT SELECT, INSERT, UPDATE, DELETE ON qa_monitor_schools TO qaat_app;

-- ─── 2. Every QA field role becomes the monitor ─────────────────────────────
UPDATE users SET role = 'QA_MONITOR'
 WHERE role IN ('QA_OFFICER','QA_PATROLLER','QA_SCHOOL_HANDLER');

-- ─── 3. Seed the join table ─────────────────────────────────────────────────
-- From the old handler-to-school table (migration 075), so a school handler's
-- several colleges survive the merge.
INSERT INTO qa_monitor_schools (user_id, tenant_id, school_id)
SELECT us.user_id, u.tenant_id, us.school_id
  FROM user_schools us
  JOIN users u ON u.user_id = us.user_id AND u.role = 'QA_MONITOR'
ON CONFLICT (tenant_id, user_id, school_id) DO NOTHING;

-- From the single free-text users.school column, matched by name OR abbreviation
-- (migration 072), exactly as 075's backfill did — a monitor filed against "SOMAC"
-- must still resolve to the School of Computing.
INSERT INTO qa_monitor_schools (user_id, tenant_id, school_id)
SELECT u.user_id, u.tenant_id, s.school_id
  FROM users u
  JOIN schools s
    ON s.tenant_id = u.tenant_id
   AND (btrim(lower(s.name)) = btrim(lower(u.school))
        OR btrim(lower(COALESCE(s.abbreviation,''))) = btrim(lower(u.school)))
 WHERE u.role = 'QA_MONITOR' AND COALESCE(u.school,'') <> ''
ON CONFLICT (tenant_id, user_id, school_id) DO NOTHING;

-- A monitor who only had rows in the join table (never a single school) still gets one name on
-- users.school, so the single-column reads that predate this migration resolve instead of
-- returning an empty page.
UPDATE users u
   SET school = sel.name
  FROM (SELECT q.user_id, q.tenant_id, MIN(s.name) AS name
          FROM qa_monitor_schools q
          JOIN schools s ON s.school_id = q.school_id
         GROUP BY q.user_id, q.tenant_id) sel
 WHERE sel.user_id = u.user_id AND sel.tenant_id = u.tenant_id
   AND COALESCE(u.school,'') = '';