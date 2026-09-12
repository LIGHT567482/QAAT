-- 109: U-Panel attendance model — lists, lecturer-opened sessions, sign-ins, awaiting-session.
--
-- Part of the migration described in docs/U-PANEL-MIGRATION.md. QAAT adopts U-Panel's
-- lecturer/session/attempt/record/sign-in split (docs/U-PANEL-MIGRATION.md §4.1) while the
-- STUDENT entry stays the in-room hub typing a registration number.
--
-- WHAT ARRIVES HERE:
--   attendance_lists        — the U-Panel attendance/lists doc: a class roster (cohort + unit)
--                             that a lecturer opens sessions under. Seeded from the existing
--                             timetable (timetable_slots x course_offerings x course_units),
--                             which already pin the cohort (offering) and unit for every lecture.
--   sessions.list_id/opened_by/opened_at — the session now names its list and who truly opened it.
--   checkin_attempts.awaiting_session/list_id/resolved_at — U-Panel's awaitingSession claim:
--                             an attempt typed before the lecturer opened keeps being retried by
--                             the sweep job instead of being rejected as "session code not found".
--   session_sign_ins         — the U-Panel attendance/sign-ins doc: a manual lecturer roster mark,
--                             deliberately separate from GPS-verified records (never merged).
--
-- WHY THE DENORMALISED LABELS ON attendance_lists. U-Panel carries program/day/year/sem on the
-- list. QAAT's cohort spine is course_offerings + course_units, and those labels are already
-- derivable — but the dashboards that group by "Day vs Evening vs Weekend" read them off the list
-- row, and resolving a label through two joins on every list render is how the cohort bug in
-- migration 065 came to be in the first place. Keeping the labels on the row, set at seed time and
-- when a list is created, makes a Weekend student's list visibly not the Day student's list.
--
-- The seed below is housekeeping, not the feature: on an empty database it creates nothing, and
-- a list the timetable does not yet cover (an unscheduled make-up, migration 086) is created on
-- demand when its session opens.

-- The verifier-written student record label. QR_SCAN survives as the "normal check-in" label for
-- historical rows (see AGENTS.md); HUB_VERIFIED marks records written by the new verifier engine.
ALTER TYPE entry_method_enum ADD VALUE IF NOT EXISTS 'HUB_VERIFIED';

-- ─── attendance_lists ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attendance_lists (
    list_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    offering_id     UUID        NOT NULL REFERENCES course_offerings (offering_id) ON DELETE CASCADE,
    unit_id         VARCHAR(50) NOT NULL REFERENCES course_units (unit_id),
    title           TEXT        NOT NULL DEFAULT '',
    room            TEXT        NOT NULL DEFAULT '',
    lecturer_id     UUID        REFERENCES lecturers (lecturer_id) ON DELETE SET NULL,
    session_variant TEXT        NOT NULL DEFAULT '',
    year_label      TEXT        NOT NULL DEFAULT '',
    semester        TEXT        NOT NULL DEFAULT '',
    program         TEXT        NOT NULL DEFAULT '',
    created_by      UUID        REFERENCES users (user_id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, offering_id, unit_id)
);

ALTER TABLE attendance_lists ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_lists FORCE  ROW LEVEL SECURITY;
CREATE POLICY "tenant_isolation" ON attendance_lists
    FOR ALL USING (tenant_id = (current_setting('app.current_tenant', true))::uuid)
    WITH CHECK (tenant_id = (current_setting('app.current_tenant', true))::uuid);

-- Ledger-ish: lists are corrected, not deleted, while sessions point at them.
GRANT SELECT, INSERT, UPDATE ON attendance_lists TO qaat_app;

CREATE INDEX IF NOT EXISTS ix_attendance_lists_offering ON attendance_lists (offering_id, unit_id);
CREATE INDEX IF NOT EXISTS ix_attendance_lists_lecturer  ON attendance_lists (lecturer_id) WHERE lecturer_id IS NOT NULL;

-- Seed one list per (cohort, unit) from the timetable, so every timetabled lecture already has a
-- roster before a single session opens. The room is the earliest slot's room (a unit can run in
-- several rooms across the week; the list's room is the display default, not a constraint).
INSERT INTO attendance_lists (tenant_id, offering_id, unit_id, title, room, year_label, semester, program)
SELECT ts.tenant_id,
       ts.offering_id,
       ts.unit_id,
       COALESCE(cu.name, ''),
       COALESCE((SELECT r.room FROM timetable_slots r
                  WHERE r.offering_id = ts.offering_id AND r.unit_id = ts.unit_id
                    AND COALESCE(r.room, '') <> ''
                  ORDER BY r.day_of_week, r.start_time LIMIT 1), ''),
       COALESCE(cu.year::text, ''),
       COALESCE(cu.semester::text, ''),
       COALESCE(c.name, '')
FROM timetable_slots ts
JOIN course_units cu ON cu.unit_id = ts.unit_id AND cu.tenant_id = ts.tenant_id
JOIN courses c       ON c.course_id = cu.course_id AND c.tenant_id = cu.tenant_id
GROUP BY ts.tenant_id, ts.offering_id, ts.unit_id, cu.name, cu.year, cu.semester, c.name
ON CONFLICT (tenant_id, offering_id, unit_id) DO NOTHING;

-- ─── sessions: list anchor + the person who opened it ─────────────────────────
ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS list_id   UUID REFERENCES attendance_lists (list_id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS opened_by UUID REFERENCES users (user_id)         ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS opened_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ix_sessions_list ON sessions (list_id) WHERE list_id IS NOT NULL;
-- The sweep job finds closed-out sessions that still owe `finalized` (migration 104).
CREATE INDEX IF NOT EXISTS ix_sessions_finalized ON sessions (session_status, finalized)
    WHERE (finalized = false AND session_status IN ('CLOSED','AUTO_CLOSED'));

-- ─── checkin_attempts: U-Panel awaiting-session claims ────────────────────────
ALTER TABLE checkin_attempts
    ADD COLUMN IF NOT EXISTS awaiting_session BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS list_id          UUID,
    ADD COLUMN IF NOT EXISTS resolved_at      TIMESTAMPTZ;

-- The sweep's worklist: typed-before-open claims, oldest first.
CREATE INDEX IF NOT EXISTS ix_attempts_awaiting ON checkin_attempts (received_at)
    WHERE awaiting_session;

-- The database-backed sweep re-links claims and stamps verdicts; both need UPDATE.
GRANT UPDATE ON checkin_attempts TO qaat_app;

-- ─── session_sign_ins: manual lecturer roster marks ───────────────────────────
CREATE TABLE IF NOT EXISTS session_sign_ins (
    sign_in_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    session_id UUID        NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    list_id    UUID        REFERENCES attendance_lists (list_id) ON DELETE SET NULL,
    student_id VARCHAR(50) NOT NULL,
    marked_by  UUID        NOT NULL REFERENCES users (user_id),
    marked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- One mark per student per session; a corrected mark is a new value on the same row, not a
    -- second row — U-Panel sign-ins are idempotent on (session, student).
    UNIQUE (session_id, student_id)
);

ALTER TABLE session_sign_ins ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_sign_ins FORCE  ROW LEVEL SECURITY;
CREATE POLICY "tenant_isolation" ON session_sign_ins
    FOR ALL USING (tenant_id = (current_setting('app.current_tenant', true))::uuid)
    WITH CHECK (tenant_id = (current_setting('app.current_tenant', true))::uuid);

GRANT SELECT, INSERT, UPDATE ON session_sign_ins TO qaat_app;
-- The manual roster mark is a witnessed ledger row like attendance_logs: it is corrected (UPDATE)
-- or superseded, never deleted.
REVOKE DELETE ON session_sign_ins FROM qaat_app;

CREATE INDEX IF NOT EXISTS ix_session_sign_ins_session ON session_sign_ins (session_id);
CREATE INDEX IF NOT EXISTS ix_session_sign_ins_student  ON session_sign_ins (btrim(lower(student_id)), marked_at DESC);