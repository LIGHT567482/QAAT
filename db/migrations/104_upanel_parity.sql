-- 104: The U-Panel features QAAT did not have, implemented locally.
--
-- Four things U-Panel records that QAAT did not. Three are small; the first is not.
--
-- 1. CHECK-IN ATTEMPTS. QAAT rejected a check-in and kept nothing at all. The student saw "you are
--    too far" and the system retained no evidence that they had ever tried. That is the wrong thing
--    to forget: the commonest attendance dispute is "I was there and it would not let me mark me
--    present", and with no record of the attempt there is nothing to examine — the student's word
--    against an absence that looks identical to never having turned up. Every attempt is now kept,
--    accepted or refused, with why and how far away they were. It is also how a lecturer discovers
--    the register was opened in the wrong place: forty rejections at 1600 metres from one room is a
--    fact about the session, not about forty students.
--
--    session_id is NULLABLE on purpose. An attempt with a mistyped code matches no session, and
--    that attempt is exactly the one worth keeping — it is how "nobody could get in" is told apart
--    from "nobody came".
--
-- 2. finalized — U-Panel marks a session closed for good, distinct from merely not being ACTIVE.
-- 3. lecturer_sign_code / lecturer_signed_at — the lecturer's own attestation on the register.
-- 4. students.three_digit_code — U-Panel gives each student a short code of their own.

CREATE TABLE IF NOT EXISTS checkin_attempts (
    attempt_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL,
    -- Null when the typed code matched nothing. See above: that is a kept attempt, not a lost one.
    session_id       UUID,
    student_id       TEXT NOT NULL DEFAULT '',
    session_code     TEXT NOT NULL DEFAULT '',
    outcome          TEXT NOT NULL,               -- PRESENT | DUPLICATE | REJECTED
    reason           TEXT NOT NULL DEFAULT '',    -- empty when accepted
    latitude         DOUBLE PRECISION,
    longitude        DOUBLE PRECISION,
    distance_meters  INTEGER,
    device_id        TEXT,
    captured_offline BOOLEAN NOT NULL DEFAULT false,
    attempted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- "Show me every attempt on this register" — the lecturer's view when something went wrong.
CREATE INDEX IF NOT EXISTS ix_attempts_session ON checkin_attempts (session_id, attempted_at DESC);
-- "Show me this student's attempts" — the view when one person disputes.
CREATE INDEX IF NOT EXISTS ix_attempts_student ON checkin_attempts (btrim(lower(student_id)), attempted_at DESC);
-- The failures alone, which is what anyone investigating actually wants.
CREATE INDEX IF NOT EXISTS ix_attempts_failed ON checkin_attempts (attempted_at DESC) WHERE outcome <> 'PRESENT';

ALTER TABLE checkin_attempts DISABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT ON checkin_attempts TO qaat_app;

ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS finalized          BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS lecturer_sign_code TEXT,
    ADD COLUMN IF NOT EXISTS lecturer_signed_at TIMESTAMPTZ;

-- U-Panel's threeDigitCode. Short, per student, and NOT a credential: three digits is a thousand
-- values across an institution, so it identifies a student to a human reading a screen and must
-- never be the thing that authorises a check-in.
ALTER TABLE students_extended
    ADD COLUMN IF NOT EXISTS three_digit_code VARCHAR(3);

COMMENT ON TABLE checkin_attempts IS
    'Every check-in attempt, accepted or refused, with the reason and the distance. Kept because a '
    'refused attempt is the evidence in the commonest attendance dispute, and QAAT previously '
    'discarded it.';
COMMENT ON COLUMN students_extended.three_digit_code IS
    'Short per-student code for human identification (U-Panel parity). Not a credential: a thousand '
    'values cannot authorise anything.';
