package upanel

import (
	"context"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// StudentRollup is one student × course/unit, counted from stored U-Panel sittings
// using the same held / attended / % fields QAAT reports and at-risk already show.
type StudentRollup struct {
	StudentID string
	FullName  string
	// WHERE THIS STUDENT SITS IN THE INSTITUTION. Filled by the resolver at import (migration 101)
	// and carried here because every QAAT attendance view is organised by department first — a
	// roll-up that cannot name one is a row the dean, the HOD and the By-College report all miss.
	// Empty when the import could not be matched; the reason is on the underlying row.
	Department string
	School     string
	Course     string
	UnitName   string
	Session    string
	Year       string
	Semester   string
	Held       int
	Attended   int
	Percentage float64
}

// LecturerRollup is contact-hour style totals from U-Panel lecture sittings.
type LecturerRollup struct {
	LecturerID string
	Name       string
	Department string
	School     string
	UnitName   string
	Sessions   int
	Hours      float64
	LastDate   string
}

// TrailEvent is one stored U-Panel attendance event, shaped like an audit row.
type TrailEvent struct {
	ID         string
	Kind       string
	Action     string
	PersonID   string
	PersonName string
	StaffID    string
	TargetType string
	TargetID   string
	Course     string
	UnitName   string
	Room       string
	EventType  string
	Present    bool
	OccurredAt time.Time
}

type StudentFilter struct {
	Course, Unit, Session, Year, Semester string
	// Org scope. An HOD sees their department, a dean their college; leaving both empty is the
	// institution-wide view the directorate gets. Applied in SQL rather than filtered in Go so a
	// bounded role never receives rows it is not entitled to in the first place.
	Department, School string
}

func AttendancePct(held, attended int) float64 {
	if held <= 0 {
		return 0
	}
	return math.Round(float64(attended)/float64(held)*1000) / 10
}

func DeficitSessions(held, attended, threshold int) int {
	if held <= 0 || threshold <= 0 {
		return 0
	}
	need := int(math.Ceil(float64(threshold) / 100.0 * float64(held)))
	if d := need - attended; d > 0 {
		return d
	}
	return 0
}

// RefreshIfEmpty pulls Contabo once when QAAT has no stored U-Panel rows yet, so
// at-risk / reports / audit can fill from the same fetch as Student Attendance.
func RefreshIfEmpty(ctx context.Context, pool *pgxpool.Pool) {
	if pool == nil {
		return
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM upanel_attendance`).Scan(&n); err != nil || n > 0 {
		return
	}
	p, err := Fetch(ctx)
	if err != nil || !p.Configured || len(p.Records) == 0 {
		return
	}
	_, _ = Upsert(ctx, pool, p.Records)
}

func StudentRollups(ctx context.Context, pool *pgxpool.Pool, f StudentFilter) ([]StudentRollup, error) {
	if pool == nil {
		return nil, nil
	}
	args := []any{}
	conds := []string{"kind = 'student'", "btrim(person_id) <> ''"}
	eq := func(col, val string) {
		val = strings.TrimSpace(val)
		if val == "" {
			return
		}
		args = append(args, val)
		conds = append(conds, col+" = $"+strconv.Itoa(len(args)))
	}
	eq("btrim(course)", f.Course)
	if u := strings.TrimSpace(f.Unit); u != "" {
		args = append(args, u, u)
		n := len(args)
		conds = append(conds, "(btrim(unit_name) = $"+strconv.Itoa(n-1)+" OR btrim(course) = $"+strconv.Itoa(n)+")")
	}
	eq("btrim(program)", f.Session)
	eq("btrim(year_label)", f.Year)
	eq("btrim(semester)", f.Semester)
	// Matched case-insensitively: department names are typed by hand in both systems, and an
	// HOD whose account says "Computer Science" must still see rows resolved as "computer science".
	if d := strings.TrimSpace(f.Department); d != "" {
		args = append(args, d)
		conds = append(conds, "btrim(lower(COALESCE(department,''))) = btrim(lower($"+strconv.Itoa(len(args))+"))")
	}
	if sc := strings.TrimSpace(f.School); sc != "" {
		args = append(args, sc)
		conds = append(conds, "btrim(lower(COALESCE(school,''))) = btrim(lower($"+strconv.Itoa(len(args))+"))")
	}

	q := `
		SELECT person_id,
		       COALESCE(NULLIF(MAX(person_name), ''), person_id),
		       COALESCE(department, ''),
		       COALESCE(school, ''),
		       COALESCE(NULLIF(course, ''), '—'),
		       COALESCE(NULLIF(unit_name, ''), NULLIF(course, ''), '—'),
		       COALESCE(NULLIF(program, ''), ''),
		       COALESCE(NULLIF(year_label, ''), ''),
		       COALESCE(NULLIF(semester, ''), ''),
		       COUNT(DISTINCT COALESCE(NULLIF(btrim(session_id), ''), occurred_at::text, record_id::text)) AS held,
		       COUNT(DISTINCT COALESCE(NULLIF(btrim(session_id), ''), occurred_at::text, record_id::text))
		           FILTER (WHERE present) AS attended
		FROM upanel_attendance
		WHERE ` + strings.Join(conds, " AND ") + `
		GROUP BY person_id, department, school, course, unit_name, program, year_label, semester
		HAVING COUNT(DISTINCT COALESCE(NULLIF(btrim(session_id), ''), occurred_at::text, record_id::text)) > 0
		ORDER BY 2, 1`

	rows, err := pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []StudentRollup{}
	for rows.Next() {
		var r StudentRollup
		if err := rows.Scan(&r.StudentID, &r.FullName, &r.Department, &r.School, &r.Course, &r.UnitName, &r.Session, &r.Year, &r.Semester, &r.Held, &r.Attended); err != nil {
			return nil, err
		}
		r.Percentage = AttendancePct(r.Held, r.Attended)
		out = append(out, r)
	}
	return out, rows.Err()
}

func LecturerRollups(ctx context.Context, pool *pgxpool.Pool) ([]LecturerRollup, error) {
	if pool == nil {
		return nil, nil
	}
	rows, err := pool.Query(ctx, `
		SELECT COALESCE(NULLIF(staff_id, ''), NULLIF(person_id, ''), NULLIF(lecturer, ''), record_id::text),
		       COALESCE(NULLIF(MAX(person_name), ''), NULLIF(MAX(lecturer), ''), MAX(staff_id), MAX(person_id)),
		       COALESCE(MAX(department), ''),
		       COALESCE(MAX(school), ''),
		       COALESCE(NULLIF(MAX(unit_name), ''), NULLIF(MAX(course), ''), ''),
		       COUNT(*),
		       COALESCE(SUM(EXTRACT(EPOCH FROM (
		           COALESCE(closed_at, occurred_at + interval '2 hours') - occurred_at
		       )) / 3600.0), 0),
		       MAX(occurred_at)
		FROM upanel_attendance
		WHERE kind = 'lecturer'
		GROUP BY 1
		ORDER BY COUNT(*) DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []LecturerRollup{}
	for rows.Next() {
		var r LecturerRollup
		var last *time.Time
		if err := rows.Scan(&r.LecturerID, &r.Name, &r.Department, &r.School, &r.UnitName, &r.Sessions, &r.Hours, &last); err != nil {
			return nil, err
		}
		if last != nil {
			r.LastDate = last.Format("2006-01-02")
		}
		if r.Sessions > 0 {
			r.Hours = math.Round(r.Hours*10) / 10
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func TrailEvents(ctx context.Context, pool *pgxpool.Pool, action, actor, from, to string, limit int) ([]TrailEvent, error) {
	if pool == nil {
		return nil, nil
	}
	if limit <= 0 || limit > 2000 {
		limit = 300
	}
	args := []any{}
	conds := []string{"occurred_at IS NOT NULL"}
	if v := strings.TrimSpace(action); v != "" {
		args = append(args, v)
		conds = append(conds, trailActionSQL()+" = $"+strconv.Itoa(len(args)))
	}
	if v := strings.TrimSpace(actor); v != "" {
		args = append(args, "%"+strings.ToLower(v)+"%")
		n := strconv.Itoa(len(args))
		conds = append(conds, "(lower(person_id) LIKE $"+n+" OR lower(person_name) LIKE $"+n+" OR lower(staff_id) LIKE $"+n+")")
	}
	if v := strings.TrimSpace(from); v != "" {
		args = append(args, v)
		conds = append(conds, "occurred_at >= $"+strconv.Itoa(len(args))+"::date")
	}
	if v := strings.TrimSpace(to); v != "" {
		args = append(args, v)
		conds = append(conds, "occurred_at < ($"+strconv.Itoa(len(args))+"::date + 1)")
	}
	args = append(args, limit)
	q := `
		SELECT record_id::text, kind, person_id, person_name, staff_id, present, event_type,
		       course, unit_name, room, session_id, occurred_at,
		       ` + trailActionSQL() + ` AS action
		FROM upanel_attendance
		WHERE ` + strings.Join(conds, " AND ") + `
		ORDER BY occurred_at DESC
		LIMIT $` + strconv.Itoa(len(args))
	rows, err := pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []TrailEvent{}
	for rows.Next() {
		var e TrailEvent
		if err := rows.Scan(&e.ID, &e.Kind, &e.PersonID, &e.PersonName, &e.StaffID, &e.Present, &e.EventType,
			&e.Course, &e.UnitName, &e.Room, &e.TargetID, &e.OccurredAt, &e.Action); err != nil {
			return nil, err
		}
		switch e.Kind {
		case KindStudent:
			e.TargetType = "student"
			if e.TargetID == "" {
				e.TargetID = e.PersonID
			}
		case KindLecturer:
			e.TargetType = "lecturer"
			if e.TargetID == "" {
				e.TargetID = firstNonEmpty(e.StaffID, e.PersonID)
			}
		default:
			e.TargetType = "staff"
			if e.TargetID == "" {
				e.TargetID = firstNonEmpty(e.StaffID, e.PersonID)
			}
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func TrailActions(ctx context.Context, pool *pgxpool.Pool) []string {
	if pool == nil {
		return nil
	}
	rows, err := pool.Query(ctx, `SELECT DISTINCT `+trailActionSQL()+` FROM upanel_attendance WHERE occurred_at IS NOT NULL ORDER BY 1`)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var a string
		if rows.Scan(&a) == nil && a != "" {
			out = append(out, a)
		}
	}
	return out
}

func AvgAndAtRisk(ctx context.Context, pool *pgxpool.Pool, threshold int) (avg float64, atRisk int) {
	rolls, err := StudentRollups(ctx, pool, StudentFilter{})
	if err != nil || len(rolls) == 0 {
		return 0, 0
	}
	seen := map[string]bool{}
	sum := 0.0
	n := 0
	for _, r := range rolls {
		sum += r.Percentage
		n++
		if r.Percentage < float64(threshold) && !seen[r.StudentID] {
			seen[r.StudentID] = true
			atRisk++
		}
	}
	if n > 0 {
		avg = math.Round(sum/float64(n)*10) / 10
	}
	return avg, atRisk
}

func trailActionSQL() string {
	return `CASE
		WHEN kind = 'student' AND present THEN 'UPANEL_STUDENT_PRESENT'
		WHEN kind = 'student' THEN 'UPANEL_STUDENT_ABSENT'
		WHEN kind = 'lecturer' THEN 'UPANEL_LECTURE'
		WHEN kind = 'admin' AND upper(event_type) IN ('OUT','DEPARTURE') THEN 'UPANEL_STAFF_OUT'
		WHEN kind = 'admin' THEN 'UPANEL_STAFF_IN'
		ELSE 'UPANEL_EVENT'
	END`
}
