package upanel

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// THE PEOPLE BEHIND THE ATTENDANCE.
//
// An imported attendance row names a student by registration number and a lecturer by name or staff
// id. If that person is not in QAAT's registry then two things follow, and the second is the one
// that matters:
//
//   They are invisible. The Students and Lecturers screens list the registry, so somebody whose
//   attendance the institution is recording does not appear on the roll at all.
//
//   Their attendance cannot be attributed. The resolver matches a registration number against
//   students_extended to find a department; no row, no match, no department — which is most of why
//   the measured match rate was zero. Creating the person is what makes the attendance resolvable.
//
// WHAT THIS DELIBERATELY DOES NOT DO IS OVERWRITE. A record entered by an administrator carries a
// verified course, department and email; one derived from an attendance feed carries a name and an
// identifier and nothing else. Letting the feed win would quietly replace checked data with
// unchecked data on every sync — so an existing row is left exactly as it is, and only genuinely
// new people are created.

// EnsurePeople creates registry rows for anyone named in imported attendance who is not already
// known. Returns how many students and lecturers were created.
func EnsurePeople(ctx context.Context, pool *pgxpool.Pool, tenantID string) (students, lecturers int, err error) {
	if pool == nil || strings.TrimSpace(tenantID) == "" {
		return 0, 0, nil
	}

	// Students. Matched on registration number, case- and whitespace-insensitively, because the
	// same number is typed by hand in both systems and " 2025-08-40174 " is the same student.
	//
	// The email is synthesised and marked, rather than left blank: the column is NOT NULL, and a
	// made-up address that is obviously made-up is safer than an empty string that some later
	// mail-merge would treat as deliverable.
	err = pool.QueryRow(ctx, `
		WITH candidates AS (
		    SELECT DISTINCT btrim(person_id) AS sid,
		           COALESCE(NULLIF(btrim(MAX(person_name)), ''), btrim(person_id)) AS name
		      FROM upanel_attendance
		     WHERE kind = 'student' AND btrim(COALESCE(person_id,'')) <> ''
		     GROUP BY btrim(person_id)
		), inserted AS (
		    INSERT INTO students_extended (
		        student_id, tenant_id, full_name, email, course_id, academic_year,
		        enrollment_status, source
		    )
		    SELECT c.sid, $1::uuid, c.name,
		           lower(regexp_replace(c.sid, '[^A-Za-z0-9]+', '.', 'g')) || '@imported.invalid',
		           'UNASSIGNED', '',
		           'ACTIVE', 'u-panel'
		      FROM candidates c
		     WHERE NOT EXISTS (
		           SELECT 1 FROM students_extended se
		            WHERE btrim(lower(se.student_id)) = btrim(lower(c.sid)))
		    RETURNING 1
		)
		SELECT COUNT(*) FROM inserted`, tenantID).Scan(&students)
	if err != nil {
		return 0, 0, err
	}

	// Lecturers. Keyed on staff id where the feed carries one and on name where it does not — which
	// is weaker, and is why an existing lecturer is never modified: matching "MK" to a real person
	// is a guess, and a guess must not be allowed to edit a real record.
	err = pool.QueryRow(ctx, `
		WITH candidates AS (
		    SELECT DISTINCT
		           NULLIF(btrim(MAX(staff_id)), '') AS staff,
		           COALESCE(NULLIF(btrim(MAX(person_name)), ''), NULLIF(btrim(MAX(lecturer)), ''),
		                    btrim(person_id)) AS name
		      FROM upanel_attendance
		     WHERE kind = 'lecturer'
		     GROUP BY btrim(person_id)
		), inserted AS (
		    INSERT INTO lecturers (tenant_id, full_name, staff_id, source)
		    SELECT $1::uuid, c.name, c.staff, 'u-panel'
		      FROM candidates c
		     WHERE btrim(COALESCE(c.name,'')) <> ''
		       AND NOT EXISTS (
		           SELECT 1 FROM lecturers l
		            WHERE (c.staff IS NOT NULL AND btrim(lower(COALESCE(l.staff_id,''))) = btrim(lower(c.staff)))
		               OR btrim(lower(l.full_name)) = btrim(lower(c.name)))
		    RETURNING 1
		)
		SELECT COUNT(*) FROM inserted`, tenantID).Scan(&lecturers)
	if err != nil {
		return students, 0, err
	}
	return students, lecturers, nil
}
