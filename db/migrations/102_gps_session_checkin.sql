-- 102: U-Panel's presence model — a session code plus a GPS geofence.
--
-- QAAT proved a student was in the room by requiring them to be ON THE COORDINATOR'S HOTSPOT: the
-- in-room server is only reachable over that Wi-Fi, so a successful POST was itself the proof. That
-- works with no signal at all, which is why it was built that way.
--
-- U-Panel proves presence differently. Its session carries a location, a radius and a short code:
-- the lecturer reads the code out, the student's phone posts its own coordinates, and the server
-- accepts the check-in when the phone is inside the circle and the window is still open. This
-- migration gives QAAT sessions the same three facts so the two systems record attendance the same
-- way and a QAAT session maps onto a U-Panel session document field for field.
--
-- WHAT THIS COSTS, RECORDED HERE BECAUSE THE COLUMNS THEMSELVES CANNOT SAY IT. U-Panel's observed
-- radius is 1500 metres, and that is what radius_meters defaults to. Fifteen hundred metres is most
-- of a campus: it admits a student in the car park, the next building, or a hall three floors up
-- who never entered this room. It is a proof of being ON CAMPUS, not of being in the lecture. The
-- hotspot check it parallels was room-sized because the radio is. This is a deliberate choice to
-- match U-Panel rather than an oversight, and the column is per-session so a tighter value can be
-- set for any session that needs one without a schema change.
--
-- The hotspot columns (checkin_secret, coordinator_ip) are LEFT IN PLACE. They are what the offline
-- coordinator app uses in a hall with no signal, and dropping them would take the system's
-- offline-first behaviour with them.

ALTER TABLE sessions
    -- Where the session was opened, as reported by the device that opened it.
    ADD COLUMN IF NOT EXISTS latitude              DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS longitude             DOUBLE PRECISION,
    -- U-Panel's default. See the note above about what this radius actually proves.
    ADD COLUMN IF NOT EXISTS radius_meters         INTEGER NOT NULL DEFAULT 1500,
    -- How good the opening fix was. A 148-metre accuracy on a 1500-metre circle is fine; the same
    -- accuracy on a 50-metre circle would mean the centre itself is barely known, so this is kept
    -- to make that judgement possible rather than invisible.
    ADD COLUMN IF NOT EXISTS gps_accuracy_meters   INTEGER,
    -- The code the lecturer reads out. Short because it is spoken across a hall.
    ADD COLUMN IF NOT EXISTS session_code          VARCHAR(8);

-- Unique among sessions that can still be joined. Not globally unique: codes are short and get
-- reused across terms, and forcing lifetime uniqueness would exhaust the space and make old rows
-- undeletable. What matters is that at any moment one typed code identifies exactly one session.
CREATE UNIQUE INDEX IF NOT EXISTS ux_sessions_active_code
    ON sessions (upper(session_code))
    WHERE session_code IS NOT NULL AND session_code <> ''
      AND session_status = 'ACTIVE';

-- The check-in path looks a session up by code on every attempt.
CREATE INDEX IF NOT EXISTS ix_sessions_code
    ON sessions (upper(session_code))
    WHERE session_code IS NOT NULL AND session_code <> '';

-- Where the STUDENT was when they checked in, kept alongside the existing device fingerprint.
-- Stored even when the check-in is accepted: the coordinates are the evidence for the decision,
-- and a later dispute cannot be settled from a boolean.
ALTER TABLE attendance_logs
    ADD COLUMN IF NOT EXISTS latitude          DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS longitude         DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS distance_meters   INTEGER,
    ADD COLUMN IF NOT EXISTS device_id         TEXT;

COMMENT ON COLUMN sessions.radius_meters IS
    'Geofence radius in metres, default 1500 to match U-Panel. At that size this proves presence '
    'on campus, not in the room — see migration 102 for the reasoning.';
COMMENT ON COLUMN attendance_logs.distance_meters IS
    'How far the student was from the session centre when accepted. Kept as evidence so a disputed '
    'record can be re-examined rather than re-argued.';
