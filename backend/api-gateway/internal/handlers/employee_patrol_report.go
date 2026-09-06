package handlers

// Employee attendance, QA OFFICE ROUND source — the human witness beside the machines.
//
// An employee's presence is now recorded three ways:
//
//	1. the badge tablet / U-Panel punch    → employee_attendance_logs
//	2. the biometric terminal's day sheet  → employee_attendance_days
//	3. a QA monitor walks to the office    → employee_patrol_logs   ← this file
//
// The first two are devices; only the third is a person. They are deliberately NOT merged and
// nothing here joins them: a turnstile and a witness answer different questions, and reconciling
// them in SQL would make one of them authoritative by implication. Each keeps its own tab and a
// human reads both — which is the same arrangement, and the same reasoning, as the coordinator's
// log and the monitor's tick on the teaching side.
//
//	GET /api/v1/dashboard/employee-attendance/patrol           — per-person summary + every visit
//	GET /api/v1/dashboard/employee-attendance/patrol/export.*  — the same, downloadable

import (
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
)

// officeVisit is one office visit by a QA monitor.
type officeVisit struct {
	VisitID string `json:"visit_id"`
	// employee_patrol_logs keys on STAFF ID — the badge number, which is also employee_attendance_days'
	// ac_no — so a disagreement with the terminal sheet can be lined up by hand.
	StaffID      string `json:"staff_id"`
	EmployeeName string `json:"employee_name"`
	Department   string `json:"department"`
	JobTitle     string `json:"job_title"`
	Office       string `json:"office"`
	// REGISTRY or TYPED. An office the monitor had to type is one the registry has wrong, and a
	// run of them for one department is a registry to go and fix — so it travels with the row
	// rather than being flattened away.
	OfficeSource string `json:"office_source"`
	// AT_OFFICE | ELSEWHERE_ON_DUTY | ABSENT. Three answers, not two: see migration 106 on why a
	// boolean would file somebody who was in a meeting as absent.
	Status    string `json:"status"`
	FoundAt   string `json:"found_at"`
	Remarks   string `json:"remarks"`
	VisitDate string `json:"visit_date"`
	VisitTime string `json:"visit_time"`
	// Who knocked. On the row and on this page, and nowhere near the message the employee gets —
	// see employee_patrol_notify.go.
	QAMonitor        string `json:"qa_monitor"`
	QAMonitorStaffID string `json:"qa_monitor_staff_id"`
	// When the phone filed it, and when it reached the server. The gap is how long the handset was
	// offline, which is part of the story of the record and not a defect in it.
	CapturedAt string `json:"captured_at"`
	ReceivedAt string `json:"received_at"`
}

// officeEmployee aggregates one person's visits.
type officeEmployee struct {
	StaffID      string  `json:"staff_id"`
	EmployeeName string  `json:"employee_name"`
	Department   string  `json:"department"`
	Office       string  `json:"office"`
	Visits       int     `json:"visits"`
	AtOffice     int     `json:"at_office"`
	Elsewhere    int     `json:"elsewhere"`
	Absent       int     `json:"absent"`
	Rate         float64 `json:"rate"` // found at their office, as a % of visits
	LastVisit    string  `json:"last_visit_date"`
}

// queryOfficeRound returns the per-person summary and the flat visit list, scoped to the caller's
// tenant and to whatever the request asked for.
func queryOfficeRound(r *http.Request, pool *pgxpool.Pool) ([]officeEmployee, []officeVisit, error) {
	tenantID := middleware.GetTenantID(r.Context())
	conn, err := pool.Acquire(r.Context())
	if err != nil {
		return nil, nil, err
	}
	defer conn.Release()
	if err := middleware.SetTenantConn(r.Context(), conn, tenantID); err != nil {
		return nil, nil, err
	}

	// Filters, in the shape EmployeeDays uses — this page is asked the same questions, so its
	// filter bar is the same filter bar.
	args := []interface{}{tenantID}
	where := ""
	if v := strings.TrimSpace(r.URL.Query().Get("from")); v != "" {
		args = append(args, v)
		where += " AND p.visit_date >= $" + itoa(len(args)) + "::date"
	}
	if v := strings.TrimSpace(r.URL.Query().Get("to")); v != "" {
		args = append(args, v)
		where += " AND p.visit_date <= $" + itoa(len(args)) + "::date"
	}
	if v := strings.TrimSpace(r.URL.Query().Get("department")); v != "" {
		args = append(args, v)
		where += " AND btrim(lower(p.department)) = btrim(lower($" + itoa(len(args)) + "))"
	}
	if v := strings.TrimSpace(r.URL.Query().Get("status")); v != "" {
		if s := strings.ToUpper(v); validOfficeStatus(s) {
			args = append(args, s)
			where += " AND p.status = $" + itoa(len(args))
		}
	}
	// One box for "who", bound once and referenced twice — a second placeholder for the same
	// value is how the numbering drifts when a filter is later added above it.
	if v := strings.TrimSpace(r.URL.Query().Get("q")); v != "" {
		args = append(args, "%"+strings.ToLower(v)+"%")
		n := itoa(len(args))
		where += " AND ( btrim(lower(p.employee_name)) LIKE $" + n +
			" OR btrim(lower(p.staff_id)) LIKE $" + n + " )"
	}

	// The visits, newest first — the detail rows behind each person.
	vRows, err := conn.Query(r.Context(), `
		SELECT p.visit_id::text, p.staff_id, COALESCE(p.employee_name,''),
		       COALESCE(p.department,''), COALESCE(p.job_title,''),
		       COALESCE(p.office,''), p.office_source, p.status,
		       COALESCE(p.found_at,''), COALESCE(p.remarks,''),
		       p.visit_date::text, p.visit_time,
		       COALESCE(p.patroller_name,''), COALESCE(p.patroller_staff_id,''),
		       p.captured_at::text, p.received_at::text
		FROM employee_patrol_logs p
		WHERE p.tenant_id = $1`+where+`
		ORDER BY p.visit_date DESC, p.visit_time DESC`, args...)
	if err != nil {
		return nil, nil, err
	}
	visits := []officeVisit{}
	for vRows.Next() {
		var v officeVisit
		if vRows.Scan(&v.VisitID, &v.StaffID, &v.EmployeeName, &v.Department, &v.JobTitle,
			&v.Office, &v.OfficeSource, &v.Status, &v.FoundAt, &v.Remarks,
			&v.VisitDate, &v.VisitTime, &v.QAMonitor, &v.QAMonitorStaffID,
			&v.CapturedAt, &v.ReceivedAt) == nil {
			visits = append(visits, v)
		}
	}
	vRows.Close()

	// Per-person rollup. `office` is MAX'd off the visits rather than joined from the registry:
	// the page is about what the round found, and the door the monitor actually knocked at is the
	// more useful answer than the one the registry has on file.
	sRows, err := conn.Query(r.Context(), `
		SELECT p.staff_id,
		       COALESCE(MAX(p.employee_name),''), COALESCE(MAX(p.department),''),
		       COALESCE(MAX(p.office),''),
		       COUNT(*)                                                AS visits,
		       COUNT(*) FILTER (WHERE p.status = 'AT_OFFICE')          AS at_office,
		       COUNT(*) FILTER (WHERE p.status = 'ELSEWHERE_ON_DUTY')  AS elsewhere,
		       COUNT(*) FILTER (WHERE p.status = 'ABSENT')             AS absent,
		       MAX(p.visit_date)::text                                 AS last_visit
		FROM employee_patrol_logs p
		WHERE p.tenant_id = $1`+where+`
		GROUP BY p.staff_id
		ORDER BY 2`, args...)
	if err != nil {
		return nil, nil, err
	}
	summary := []officeEmployee{}
	for sRows.Next() {
		var s officeEmployee
		if sRows.Scan(&s.StaffID, &s.EmployeeName, &s.Department, &s.Office,
			&s.Visits, &s.AtOffice, &s.Elsewhere, &s.Absent, &s.LastVisit) == nil {
			if s.Visits > 0 {
				s.Rate = float64(int(float64(s.AtOffice)/float64(s.Visits)*1000+0.5)) / 10
			}
			summary = append(summary, s)
		}
	}
	sRows.Close()

	return summary, visits, nil
}

// GET /api/v1/dashboard/employee-attendance/patrol
func EmployeeOfficeRound(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		summary, visits, err := queryOfficeRound(r, pool)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		// The departments actually present in the round, so the filter offers real values rather
		// than every support department including the ones no monitor has ever walked. Same move
		// EmployeeDays makes, and for the same reason.
		seen := map[string]bool{}
		departments := []string{}
		for _, v := range visits {
			d := strings.TrimSpace(v.Department)
			if d != "" && !seen[d] {
				seen[d] = true
				departments = append(departments, d)
			}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"summary":     summary,
			"visits":      visits,
			"departments": departments,
			"count":       len(visits),
		})
	}
}

// officeStatusLabel renders a verdict for a reader, not for the database.
//
// ABSENT must not print as "Absent". The column says what was SEEN, and what was seen is that the
// office was empty — which is a smaller claim, and the only one a single knock supports. The same
// move patrolAttendanceTable makes for PATROL/MANUAL, and it matters more here because this row
// travels out of the building as a spreadsheet.
func officeStatusLabel(status string) string {
	switch status {
	case "AT_OFFICE":
		return "At their office"
	case "ELSEWHERE_ON_DUTY":
		return "Elsewhere, on duty"
	case "ABSENT":
		return "Office empty"
	}
	return status
}

// officeRoundTable flattens the round for download.
//
// Takes the visits rather than the request, deliberately: there is no database test harness in
// this package, and a table builder that needs an *http.Request cannot be checked at all. The
// download is the VISITS, not the rollup — the screen already answers "how is this person doing",
// and a download is asked for when somebody needs the underlying observations, which are worthless
// without the observer on them.
func officeRoundTable(visits []officeVisit) reportTable {
	t := reportTable{
		Title:    "Employee Attendance — QA office round",
		Subtitle: itoa(len(visits)) + " office visit(s) by a QA monitor",
		Headers: []string{"Date", "Time", "Employee", "Staff ID", "Department", "Job title",
			"Office", "Office from", "Found", "Where instead", "Remarks",
			"QA Monitor", "Monitor ID", "Recorded", "Received"},
		Weights: []float64{1.4, 0.9, 2.6, 1.3, 2, 2, 1.8, 1.1, 1.6, 2, 2.4, 2.2, 1.3, 1.7, 1.7},
	}
	for _, v := range visits {
		from := "Registry"
		if v.OfficeSource != "REGISTRY" {
			from = "Typed"
		}
		t.Rows = append(t.Rows, []string{
			v.VisitDate, v.VisitTime, v.EmployeeName, v.StaffID, v.Department, v.JobTitle,
			v.Office, from, officeStatusLabel(v.Status), v.FoundAt, v.Remarks,
			v.QAMonitor, v.QAMonitorStaffID, v.CapturedAt, v.ReceivedAt,
		})
	}
	return t
}

// GET /api/v1/dashboard/employee-attendance/patrol/export.{xlsx,csv,pdf}
func EmployeeOfficeRoundExport(pool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_, visits, err := queryOfficeRound(r, pool)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		writeReport(w, r, pool, format, "employee-office-round", officeRoundTable(visits))
	}
}
