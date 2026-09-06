-- 103: Attendance captured with no signal, uploaded when there is one.
--
-- The hotspot is gone. It solved the no-signal problem by not needing a network at all — the
-- coordinator's phone WAS the server — and with it removed, a hall with no coverage has no way to
-- record anybody. So the app now captures locally and uploads later.
--
-- THE HONEST DIFFERENCE, WHICH THESE COLUMNS EXIST TO PRESERVE. A hotspot check-in was witnessed as
-- it happened: the student's phone had to reach a server in the room, so the record was made by
-- something other than the student's own claim. An offline capture is the student's phone asserting
-- afterwards that it was somewhere at some time. Both end up as a row in the same table, and if
-- they were stored identically nobody reading the register later could tell which kind they were
-- looking at.
--
--   captured_at  — when the phone says the student checked in. Comes from the device clock, which
--                  the student can change.
--   received_at  — when the server actually got it. Cannot be forged by a client.
--   captured_offline — whether this was queued rather than live.
--   client_queue_id  — the phone's own id for the queued item, so a retry that arrives twice after
--                  a flaky upload is recognised as the same event and not counted again.
--
-- Keeping captured_at and received_at APART is the point. A large gap is not proof of anything on
-- its own — a genuine lecture in a basement uploads hours later — but it is the fact a QA officer
-- needs in order to ask. Collapsing them into one timestamp would destroy the only signal that
-- distinguishes a delayed honest upload from a fabricated one.

ALTER TABLE attendance_logs
    ADD COLUMN IF NOT EXISTS captured_at       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS received_at       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS captured_offline  BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS client_queue_id   TEXT;

-- One queued item can only ever produce one row, however many times a flaky connection retries it.
-- Partial, because only offline captures carry a queue id.
CREATE UNIQUE INDEX IF NOT EXISTS ux_attendance_client_queue
    ON attendance_logs (client_queue_id)
    WHERE client_queue_id IS NOT NULL AND client_queue_id <> '';

-- The reconciliation worklist: offline rows, newest upload first.
CREATE INDEX IF NOT EXISTS ix_attendance_offline
    ON attendance_logs (captured_offline, received_at DESC)
    WHERE captured_offline;

COMMENT ON COLUMN attendance_logs.captured_at IS
    'When the DEVICE says the check-in happened. Device clocks are settable by their owner; compare '
    'against received_at rather than trusting this alone.';
COMMENT ON COLUMN attendance_logs.received_at IS
    'When the SERVER received the record. Not forgeable by a client, so this is the anchor a '
    'disputed offline capture is judged against.';
