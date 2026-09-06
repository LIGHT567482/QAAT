-- 105: U-Panel's students and lecturers become QAAT's students and lecturers.
--
-- Attendance imported from U-Panel names people QAAT's registry has never heard of — seven students
-- and four lecturers at the time of writing. Until now those names existed only inside attendance
-- rows, which had two consequences and both are bad:
--
--   The Students and Lecturers screens did not list them, so an administrator looking at the roll
--   could not see people the institution is already recording attendance for.
--
--   Nothing could be attributed. The resolver matches attendance by registration number against
--   students_extended; a student who is not in that table cannot match, which is most of why the
--   measured match rate was zero. Importing the PEOPLE is what makes importing the ATTENDANCE work.
--
-- PROVENANCE IS RECORDED, because these records are not the same kind of thing as one an admissions
-- officer typed. A row that arrived from an attendance feed has no course, no department and no
-- verified email — it is a name and an identifier. Marking it lets the registry show what still
-- needs completing rather than presenting a half-record as if it were checked, and lets a future
-- import update its own rows without ever touching one a human entered.

ALTER TABLE students_extended
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'qaat';
ALTER TABLE lecturers
    ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'qaat';

-- course_id is NOT NULL on students_extended and U-Panel supplies no course, so imported students
-- need somewhere to sit until an administrator assigns them. A single explicit placeholder course
-- is better than a nullable column: it keeps every existing query working unchanged, and it makes
-- "not yet assigned" a visible row in the course list rather than an invisible NULL that each
-- report would have to remember to handle.
INSERT INTO courses (course_id, tenant_id, name, department, school)
SELECT 'UNASSIGNED', t.tenant_id, 'Unassigned (imported)', NULL, NULL
  FROM tenants t
 WHERE t.tenant_id <> '00000000-0000-0000-0000-000000000000'
ON CONFLICT (course_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS ix_students_source ON students_extended (source) WHERE source <> 'qaat';
CREATE INDEX IF NOT EXISTS ix_lecturers_source ON lecturers (source) WHERE source <> 'qaat';

COMMENT ON COLUMN students_extended.source IS
    'Where this record came from: qaat (entered here) or u-panel (created from an imported '
    'attendance feed, so it carries a name and id but no verified course or department yet).';
