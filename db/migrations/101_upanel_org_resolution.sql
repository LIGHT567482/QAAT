-- 101: Attach imported U-Panel attendance to the school/department spine.
--
-- Migration 100 mirrors U-Panel documents flat: course, unit_name, lecturer, room and program
-- arrive as FREE TEXT with nothing linking them to QAAT's own org tree. That makes the imported
-- rows an island. Every report the directorate reads begins at a school or a department — By
-- College, Course Health, the at-risk watchlist, the QA round — and none of them can see a row
-- whose department is a string that was never matched against anything.
--
-- So each imported row now records WHAT IT RESOLVED TO and, when it resolved to nothing, WHY.
--
-- The "why" is the part that matters most. A resolver that silently drops what it cannot match
-- makes absence and failure look identical: a unit whose name U-Panel spells differently would
-- simply appear to have no attendance, and the number would be quietly wrong rather than visibly
-- missing. Keeping the reason turns that into something a person can find and fix — usually by
-- correcting one name in one place.
--
-- Nothing here is destructive: the free-text columns from 100 stay exactly as imported, because
-- they are the evidence of what U-Panel actually said. These columns sit beside them as QAAT's
-- interpretation, and a re-import can revise the interpretation without touching the record.

ALTER TABLE upanel_attendance
    ADD COLUMN IF NOT EXISTS unit_id       TEXT,
    ADD COLUMN IF NOT EXISTS department    TEXT,
    ADD COLUMN IF NOT EXISTS school        TEXT,
    -- Which rule matched, so a reader can tell a confident id match from a fuzzy name match.
    -- 'student' | 'unit' | 'course' | 'lecturer' | '' (unresolved)
    ADD COLUMN IF NOT EXISTS resolved_via  TEXT NOT NULL DEFAULT '',
    -- Empty when resolved. Otherwise the specific reason, in words a registrar can act on.
    ADD COLUMN IF NOT EXISTS unresolved    TEXT NOT NULL DEFAULT '';

-- The reports filter by department and school, and the unresolved queue is read as a worklist.
CREATE INDEX IF NOT EXISTS ix_upanel_attendance_dept
    ON upanel_attendance (department, occurred_at DESC NULLS LAST)
    WHERE department IS NOT NULL AND department <> '';

CREATE INDEX IF NOT EXISTS ix_upanel_attendance_unresolved
    ON upanel_attendance (imported_at DESC)
    WHERE unresolved <> '';

COMMENT ON COLUMN upanel_attendance.unresolved IS
    'Why this imported row could not be attached to a QAAT department. Empty means resolved. '
    'Rows with a reason are counted and shown rather than dropped, so a naming mismatch surfaces '
    'as a fixable queue instead of as missing attendance.';
