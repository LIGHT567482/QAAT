-- 106: The office round — a human witness beside the employee attendance machine.
--
-- WHAT IS WRONG TODAY. Employee attendance is captured entirely by machines. Badge punches land in
-- employee_attendance_logs from a tablet import (source TABLET) and from U-Panel campus presence
-- (source UPANEL); the biometric terminal's 29-column daily sheet lands in
-- employee_attendance_days, stored verbatim (migration 077). Every one of those is a device's
-- account of a person, and nobody has ever walked to the door. A badge can be tapped by a
-- colleague. The terminal says somebody clocked in at 08:00 and nothing in the institution says
-- whether they were at their desk at 11:00.
--
-- WHAT THIS IS. The teaching side has had two independent accounts of every lecture since
-- migration 058: the coordinator's session log, and the QA monitor's patrol tick. They are
-- deliberately NOT merged, because where they disagree is the finding quality assurance exists to
-- produce. This table is to the terminal sheet what lecturer_patrol_logs is to the coordinator's
-- log — a QA monitor walks office to office and records what was behind the door.
--
-- WHAT IT IS NOT. It is not a clock event, it does not mark anybody present or absent for payroll,
-- and nothing here is ever reconciled against the machine records by anything but a human reading
-- both. One knock establishes that at that minute that door had nobody behind it. It does not
-- establish absence from work.
--
-- WHY NOT A ROW IN employee_attendance_logs WITH source='MONITOR'. Two reasons, and the first is
-- fatal. An ABSENT finding has no punch to write: the whole observation is that nothing happened,
-- and that table's shape is one row per event. And summarizePunches (employee_attendance.go)
-- counts a worked day as (hasIn AND hasOut) OR count >= 2 — so a pair of monitor rows would forge
-- a worked day out of a finding that the office was empty. The witness would silently become the
-- thing it was brought in to check.

-- ── Where to knock ───────────────────────────────────────────────────────────
--
-- The round is search-first over the employee registry, and the registry is what supplies the
-- office it prefills. There is no offices table and this does not create one: an office is a label
-- on a door, it changes without telling anybody, and a registry of them would be wrong within a
-- term. The value here is the monitor's starting point, never the answer — what they actually
-- found is recorded on the visit.
--
-- NOT REQUIRED, unlike department. A support department is required on an employee because the
-- no-show report GROUPs BY it and a blank one makes a person unchaseable; an office is a
-- convenience the monitor can always override, and refusing an employee for want of one would
-- block the registry on a fact HR's own file has never carried.
ALTER TABLE employees ADD COLUMN IF NOT EXISTS office VARCHAR(160);

COMMENT ON COLUMN employees.office IS
    'Where this person is normally found — a room or door label, free text. Prefills the QA '
    'office round; the monitor records what they actually found, which may differ.';

-- ── One office visit ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS employee_patrol_logs (
    -- MINTED ON THE HANDSET, as lecturer_presence_claims does (migration 081) and for the same
    -- reason: the round is filed offline and uploaded later, so a batch retried after a timeout —
    -- the normal case on the connection these travel over — must not file the same visit twice.
    -- See the note under the table for why this, and not a natural slot key.
    visit_id              UUID         PRIMARY KEY,
    tenant_id             UUID         NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,

    -- WHO was looked for. staff_id is the badge number that employee_attendance_days keys on as
    -- ac_no and that employee_attendance_logs keys on directly — it is what lines this record up
    -- against the machine ones. The rest is COPIED rather than joined, so the visit still reads if
    -- the registry row is later edited or the person leaves.
    staff_id              VARCHAR(60)  NOT NULL,
    employee_name         TEXT         NOT NULL DEFAULT '',
    department            VARCHAR(160) NOT NULL DEFAULT '',
    job_title             VARCHAR(160) NOT NULL DEFAULT '',

    -- WHERE the monitor knocked, and whether that was the registry's answer or their own.
    -- office_source is not bookkeeping: an office the monitor had to type is one the registry has
    -- wrong, and a run of TYPED rows for one department is a registry to go and fix.
    office                TEXT         NOT NULL DEFAULT '',
    office_source         TEXT         NOT NULL DEFAULT 'TYPED'
        CHECK (office_source IN ('REGISTRY', 'TYPED')),

    -- WHAT WAS FOUND. Three answers, not two.
    --
    --   AT_OFFICE          — found where they are supposed to be.
    --   ELSEWHERE_ON_DUTY  — not at the office, but the monitor established where they were
    --                        (a meeting, a campus errand, another desk). found_at says where.
    --   ABSENT             — the office was empty and nobody could say where they were.
    --
    -- A boolean would collapse the middle case into ABSENT, which is a false accusation against
    -- somebody who was working — the office equivalent of marking a lecturer NOT TAUGHT because
    -- the class moved room, which is exactly what found_venue on lecturer_patrol_logs exists to
    -- prevent. Only ABSENT is reported to the person, so the distinction is not cosmetic.
    status                TEXT         NOT NULL
        CHECK (status IN ('AT_OFFICE', 'ELSEWHERE_ON_DUTY', 'ABSENT')),
    found_at              TEXT         NOT NULL DEFAULT '',
    remarks               TEXT         NOT NULL DEFAULT '',

    -- WHEN, by the phone that filed it, and when it reached us. The gap between the two is how
    -- long the handset was offline, which is part of the story of the record — see 081 and 104.
    --
    -- visit_date and visit_time are DERIVED server-side from captured_at rather than sent
    -- alongside it: there is no timetable here to anchor a date to, so a phone that sent a date
    -- and a timestamp that disagreed would file a visit on a day it did not happen.
    captured_at           TIMESTAMPTZ  NOT NULL,
    visit_date            DATE         NOT NULL,
    visit_time            VARCHAR(5)   NOT NULL,          -- 'HH:MM'
    received_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),

    -- WHO LOOKED. Stored on the row and read by the QA reports; the person the visit is about is
    -- never shown this name. See patrolSenderName in patrol_notify.go for why.
    patroller_id          UUID         NOT NULL,
    patroller_name        VARCHAR(200) NOT NULL DEFAULT '',
    patroller_staff_id    VARCHAR(50)  NOT NULL DEFAULT '',
    patroller_device_hash TEXT         NOT NULL DEFAULT '',

    entry_method          TEXT         NOT NULL DEFAULT 'OFFICE_ROUND',
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ── THE IDEMPOTENCY KEY, AND WHY IT IS NOT A SLOT ────────────────────────────
--
-- lecturer_patrol_logs keys on (unit, session_date, scheduled_time, offering) and a re-tick
-- UPDATEs. That works because the TIMETABLE supplies scheduled_time: a coordinate both the phone
-- and the server compute independently, agreed in advance by somebody other than the monitor, so a
-- second tick against it is by definition a correction of the first.
--
-- An office visit has no such coordinate. There is no schedule of visits and no offices registry,
-- and nothing says a given person is due to be checked at a given hour. The only time available is
-- the moment the monitor tapped — which is DATA, not a key.
--
-- And the case that settles it: a monitor may legitimately call at the same office twice in one
-- day, at 09:00 and again at 15:30. Under a (staff_id, visit_date) key the second would overwrite
-- the first, and a record showing somebody absent in the morning and present in the afternoon —
-- the most useful thing this round can produce — would come out as one row.
--
-- So the key is the id the handset mints, as migration 081. A retry is the same visit; a
-- correction re-sends the same id and UPDATEs; a genuine second call is a new id and a new row.
--
-- The index below is the mis-tap guard and only that: one monitor cannot record the same person
-- twice in the same minute. Two DIFFERENT monitors in the same minute are two observations and
-- both survive, which is why patroller_id is in the key.
CREATE UNIQUE INDEX IF NOT EXISTS ux_employee_visit_moment
    ON employee_patrol_logs (tenant_id, staff_id, visit_date, visit_time, patroller_id);

-- What the QA screen queries: a window of visits, newest first.
CREATE INDEX IF NOT EXISTS ix_employee_patrol_date
    ON employee_patrol_logs (tenant_id, visit_date DESC);
-- The other direction: one person's visits, which is how a disagreement with the terminal sheet is
-- read — line this up against employee_attendance_days for the same ac_no and day.
CREATE INDEX IF NOT EXISTS ix_employee_patrol_staff
    ON employee_patrol_logs (tenant_id, staff_id, visit_date);

-- One institution, so no RLS — see migrations 095 and 104. tenant_id stays on the row and every
-- query scopes on it explicitly; nothing here relies on a join to employees for isolation.
ALTER TABLE employee_patrol_logs DISABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON employee_patrol_logs TO qaat_app;

-- No DELETE. An observation about a named person that the office it is filed against can make
-- disappear is not evidence of anything. A visit recorded in error is corrected by re-sending its
-- id with the right verdict, which leaves the row and its captured_at intact.
REVOKE DELETE ON employee_patrol_logs FROM qaat_app;

COMMENT ON TABLE employee_patrol_logs IS
    'A QA monitor''s own record of walking to an employee''s office: who was looked for, which '
    'door, what was behind it, when, and who knocked. The human witness beside the badge punches '
    'and the terminal sheet. Never merged with either — where they disagree is the finding.';

-- The alert kind this round adds to the notification_log family of migration 073:
-- EMPLOYEE_OFFICE_ABSENT, claimed per (staff_id, visit_date) so one empty office produces one
-- message however many times the round syncs.
