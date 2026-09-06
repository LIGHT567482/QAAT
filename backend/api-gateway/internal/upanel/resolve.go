package upanel

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ATTACHING IMPORTED ATTENDANCE TO THE SCHOOL/DEPARTMENT SPINE.
//
// U-Panel records a lecture as text: a course name, a unit name, a lecturer's name, a programme.
// QAAT reports on an org tree: schools contain departments, departments own courses, courses own
// units. Every figure the directorate reads starts at that tree, so an imported row that is not
// attached to it cannot appear in any of them — By College, Course Health, the at-risk watchlist
// all begin with a department and would simply never see it.
//
// This is the join between the two, and it is deliberately ORDERED BY CONFIDENCE rather than by
// convenience. A registration number is issued by the institution and appears in both systems
// unchanged, so matching on it is near-certain. A unit code is nearly as good. A course or unit
// NAME is a human typing the same thing twice in two systems, which is where "Structured
// Programming" and "Fundamentals of Programming" turn out to be one unit — so names are tried
// last, and the row records which rule matched so a reader can weigh it.
//
// WHAT HAPPENS WHEN NOTHING MATCHES IS THE POINT. The row is kept, with a reason. A resolver that
// dropped it would make a spelling difference indistinguishable from an empty hall: the unit would
// show no attendance and the number would be wrong in a way nobody could see. Kept-with-a-reason
// turns it into a worklist a registrar can clear, usually by fixing one name.

// Resolution is what QAAT decided a U-Panel row refers to. Empty Department with a non-empty
// Unresolved is a complete, honest answer — not a failure to be discarded.
type Resolution struct {
	UnitID     string
	Department string
	School     string
	Via        string // student | unit | course | lecturer | "" when unresolved
	Unresolved string // empty when resolved; otherwise why, in words a registrar can act on
}

// orgIndex is the QAAT side of the join, loaded once per import rather than queried per row: a
// full sync is thousands of records against a few hundred units, and a lookup per row would turn
// one import into thousands of round trips.
type orgIndex struct {
	byStudent  map[string]Resolution // reg-no (normalised) -> org
	byUnitID   map[string]Resolution // unit code (normalised)
	byUnitName map[string]Resolution // unit name (normalised)
	byCourse   map[string]Resolution // course name AND course code
	byLecturer map[string]Resolution // lecturer full name (normalised)
	// Names that map to MORE than one department are recorded here and never matched: guessing
	// between two departments is worse than admitting the name is ambiguous, because a wrong
	// attribution silently moves attendance from one college's report into another's.
	ambiguous map[string]bool
}

func norm(s string) string {
	return strings.Join(strings.Fields(strings.ToLower(strings.TrimSpace(s))), " ")
}

// put records a mapping, marking the key ambiguous if it already points somewhere different.
func put(m map[string]Resolution, amb map[string]bool, key string, r Resolution) {
	if key == "" {
		return
	}
	if prev, ok := m[key]; ok {
		if prev.Department != r.Department || prev.School != r.School {
			amb[key] = true
		}
		return
	}
	m[key] = r
}

// LoadOrgIndex reads QAAT's org tree once, ready to resolve a batch against it.
func LoadOrgIndex(ctx context.Context, pool *pgxpool.Pool) (*orgIndex, error) {
	ix := &orgIndex{
		byStudent: map[string]Resolution{}, byUnitID: map[string]Resolution{},
		byUnitName: map[string]Resolution{}, byCourse: map[string]Resolution{},
		byLecturer: map[string]Resolution{}, ambiguous: map[string]bool{},
	}

	// Units carry the strongest signal after the student: a unit belongs to exactly one course,
	// and the course names its department and college. LEFT JOINs throughout because a department
	// with no school is normal here — the support departments (Library, ICT, Bursary) sit under no
	// faculty, and inner-joining them away would silently drop their attendance entirely.
	rows, err := pool.Query(ctx, `
		SELECT cu.unit_id, COALESCE(cu.name,''),
		       COALESCE(c.course_id,''), COALESCE(c.name,''),
		       COALESCE(c.department,''), COALESCE(c.school,'')
		  FROM course_units cu
		  LEFT JOIN courses c ON c.course_id = cu.course_id`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var unitID, unitName, courseID, courseName, dept, school string
		if rows.Scan(&unitID, &unitName, &courseID, &courseName, &dept, &school) != nil {
			continue
		}
		r := Resolution{UnitID: unitID, Department: dept, School: school}
		put(ix.byUnitID, ix.ambiguous, norm(unitID), Resolution{unitID, dept, school, "unit", ""})
		put(ix.byUnitName, ix.ambiguous, norm(unitName), Resolution{unitID, dept, school, "unit", ""})
		// A course maps to a department but NOT to one unit, so no unit_id is claimed here.
		put(ix.byCourse, ix.ambiguous, norm(courseID), Resolution{"", dept, school, "course", ""})
		put(ix.byCourse, ix.ambiguous, norm(courseName), Resolution{"", dept, school, "course", ""})
		_ = r
	}
	rows.Close()

	// Students: a registration number is institution-issued and identical in both systems, which
	// makes this the one match that is essentially never wrong.
	sRows, err := pool.Query(ctx, `
		SELECT se.student_id, COALESCE(c.department,''), COALESCE(c.school,'')
		  FROM students_extended se
		  LEFT JOIN courses c ON c.course_id = se.course_id`)
	if err != nil {
		return nil, err
	}
	for sRows.Next() {
		var sid, dept, school string
		if sRows.Scan(&sid, &dept, &school) == nil {
			put(ix.byStudent, ix.ambiguous, norm(sid), Resolution{"", dept, school, "student", ""})
		}
	}
	sRows.Close()

	// Lecturers, via the units they are assigned to. Weakest of the four: a lecturer who teaches
	// across two departments is common and correct, and put() marks them ambiguous rather than
	// picking one.
	lRows, err := pool.Query(ctx, `
		SELECT DISTINCT COALESCE(l.full_name,''), COALESCE(c.department,''), COALESCE(c.school,'')
		  FROM lecturers l
		  JOIN lecturer_assignments la ON la.lecturer_id = l.lecturer_id
		  JOIN course_units cu ON cu.unit_id = la.unit_id
		  LEFT JOIN courses c ON c.course_id = cu.course_id`)
	if err != nil {
		return nil, err
	}
	for lRows.Next() {
		var name, dept, school string
		if lRows.Scan(&name, &dept, &school) == nil {
			put(ix.byLecturer, ix.ambiguous, norm(name), Resolution{"", dept, school, "lecturer", ""})
		}
	}
	lRows.Close()

	return ix, nil
}

// Resolve attaches one imported record to the org tree, strongest signal first.
func (ix *orgIndex) Resolve(rec Record) Resolution {
	type attempt struct {
		key string
		m   map[string]Resolution
	}
	// Order is confidence order, and it is the whole design: an institution-issued id beats a
	// typed name every time, so a row is only ever matched on a name when no id matched.
	student := firstNonEmpty(rec.StudentID, rec.PersonID)
	for _, a := range []attempt{
		{norm(student), ix.byStudent},
		{norm(rec.Unit), ix.byUnitID},
		{norm(firstNonEmpty(rec.UnitName, rec.Unit)), ix.byUnitName},
		{norm(rec.Course), ix.byCourse},
		{norm(firstNonEmpty(rec.LecturerName, rec.Lecturer)), ix.byLecturer},
	} {
		if a.key == "" || ix.ambiguous[a.key] {
			continue
		}
		if r, ok := a.m[a.key]; ok && (r.Department != "" || r.School != "") {
			return r
		}
	}

	// Nothing matched. Say which identifiers were tried, because "no attendance" and "the unit is
	// spelled differently in the two systems" look identical in a report and are fixed differently.
	tried := []string{}
	for label, v := range map[string]string{
		"student": student, "unit": firstNonEmpty(rec.Unit, rec.UnitName),
		"course": rec.Course, "lecturer": firstNonEmpty(rec.LecturerName, rec.Lecturer),
	} {
		if strings.TrimSpace(v) != "" {
			tried = append(tried, label+"="+strings.TrimSpace(v))
		}
	}
	if len(tried) == 0 {
		return Resolution{Unresolved: "the record names no student, unit, course or lecturer"}
	}
	sortStrings(tried)
	return Resolution{Unresolved: "no QAAT department matches " + strings.Join(tried, ", ")}
}

// sortStrings keeps the reason string stable, so the same unmatched row does not look like a new
// problem on every import just because a map iterated in a different order.
func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// DryRun resolves a batch WITHOUT writing anything, and reports how well the two systems line up.
//
// This exists because the answer decides a design question rather than a detail: if most rows
// match on a registration number the import is sound as it stands, and if most only match on a
// typed name — or match nothing — then U-Panel needs to carry QAAT's identifiers and no amount of
// matching here will fix it. Running it first means that is measured before anything is written.
type DryRunReport struct {
	Total      int            `json:"total"`
	Resolved   int            `json:"resolved"`
	Unresolved int            `json:"unresolved"`
	ByRule     map[string]int `json:"by_rule"`
	Samples    []string       `json:"unresolved_samples"`
}

func DryRun(ctx context.Context, pool *pgxpool.Pool, recs []Record) (DryRunReport, error) {
	rep := DryRunReport{ByRule: map[string]int{}, Samples: []string{}}
	ix, err := LoadOrgIndex(ctx, pool)
	if err != nil {
		return rep, err
	}
	for _, rec := range recs {
		rep.Total++
		r := ix.Resolve(rec)
		if r.Unresolved != "" {
			rep.Unresolved++
			if len(rep.Samples) < 10 {
				rep.Samples = append(rep.Samples, r.Unresolved)
			}
			continue
		}
		rep.Resolved++
		rep.ByRule[r.Via]++
	}
	return rep, nil
}
