package handlers

// Downloadable reports — every report in the Reports hub can be taken away as an Excel
// workbook, a CSV or a PDF, whichever the admin needs:
//
//	GET /api/v1/dashboard/qa/student-attendance/export.{xlsx,csv,pdf}
//	GET /api/v1/dashboard/lecturer-attendance/export.{xlsx,csv,pdf}          (coordinator record)
//	GET /api/v1/dashboard/lecturer-attendance/patrol/export.{xlsx,csv,pdf}   (QA patrol record)
//	GET /api/v1/admin/tenants/{tenant_id}/employee-attendance/export.{xlsx,csv,pdf}
//	GET /api/v1/reports/lecturer-teaching/export.{xlsx,csv,pdf}
//
// Each exporter reuses the SAME handler the on-screen report is drawn from — invoked
// here and its JSON captured — so a download can never drift from the table the admin
// is looking at, and every filter, role guard and org scope applies unchanged.

import (
	"bytes"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"unicode"

	"github.com/go-pdf/fpdf"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/middleware"
)

// reportTable is the shape both writers render: a titled grid of strings.
type reportTable struct {
	Title    string
	Subtitle string
	Headers  []string
	// Relative column weights for the PDF. Empty = equal columns.
	Weights []float64
	Rows    [][]string
}

// captureJSON runs an existing report handler against this request and hands back the
// JSON it produced. A non-200 is forwarded to the client verbatim (ok=false), so an
// export inherits the report's own error handling — including its authorisation.
func captureJSON(h http.HandlerFunc, w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	rec := httptest.NewRecorder()
	h(rec, r)
	if rec.Code != http.StatusOK {
		for k, v := range rec.Header() {
			w.Header()[k] = v
		}
		w.WriteHeader(rec.Code)
		_, _ = w.Write(rec.Body.Bytes())
		return nil, false
	}
	return rec.Body.Bytes(), true
}

// reportTenantName resolves the institution name for the PDF letterhead. Best-effort:
// an unnamed tenant just yields a header without one.
func reportTenantName(r *http.Request, pool *pgxpool.Pool, tenantID string) string {
	var name string
	_ = pool.QueryRow(r.Context(), `SELECT COALESCE(name,'') FROM tenants WHERE tenant_id = $1`, tenantID).Scan(&name)
	return name
}

// writeReportCSV sends the table as a .csv download — the format spreadsheets, SIS imports and
// statistics tools all read without ceremony.
func writeReportCSV(w http.ResponseWriter, filename string, t reportTable) {
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, filename))
	// Before the first row: Excel reads a downloaded .csv as the system codepage unless the file
	// opens with this, which is how a correct UTF-8 export still showed "â€"" on a marker's screen.
	writeCSVBOM(w)
	cw := csv.NewWriter(w)
	_ = cw.Write(t.Headers)
	for _, row := range t.Rows {
		// Pad short rows so every line has the same column count.
		if len(row) < len(t.Headers) {
			padded := make([]string, len(t.Headers))
			copy(padded, row)
			row = padded
		}
		_ = cw.Write(row)
	}
	cw.Flush()
}

// writeReport dispatches one table to whichever format the caller asked for. `stem` is the
// filename without an extension.
func writeReport(w http.ResponseWriter, r *http.Request, pool *pgxpool.Pool, format, stem string, t reportTable) {
	switch format {
	case "csv":
		writeReportCSV(w, stem+".csv", t)
	case "pdf":
		writeReportPDF(w, stem+".pdf", reportTenantName(r, pool, middleware.GetTenantID(r.Context())), t)
	default: // xlsx
		writeReportXLSX(w, stem+".xlsx", t)
	}
}

// formatFloat1 renders a rate/average to one decimal place.
func formatFloat1(f float64) string { return fmt.Sprintf("%.1f", f) }

// writeReportXLSX sends the table as an .xlsx download.
func writeReportXLSX(w http.ResponseWriter, filename string, t reportTable) {
	rows := make([][]string, 0, len(t.Rows)+1)
	rows = append(rows, t.Headers)
	rows = append(rows, t.Rows...)
	data, err := buildXLSX(rows)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
		return
	}
	w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, filename))
	_, _ = w.Write(data)
}

// writeReportPDF sends the table as a landscape A4 PDF: the institution logo + a report
// letterhead, a banded grid that repeats its header on every page, and a page counter. Cells
// WRAP to their full height instead of clipping, so a long name or finding is never lost.
func writeReportPDF(w http.ResponseWriter, filename, institution string, t reportTable) {
	const (
		pageW   = 297.0 // A4 landscape
		pageH   = 210.0
		margin  = 12.0
		usableW = pageW - 2*margin
		bottom  = 16.0
	)
	pdf := fpdf.New("L", "mm", "A4", "")
	pdf.SetMargins(margin, margin, margin)
	pdf.SetAutoPageBreak(true, bottom)
	// Every string below goes through this. The core fonts are cp1252, and handing them raw UTF-8
	// is what turned every em dash into "â€"". See report_text.go — it also has to happen BEFORE
	// the width measurements further down, or those operate on the wrong bytes.
	enc := pdfEncoder(pdf)

	// Column widths from the relative weights (equal when none were given).
	weights := t.Weights
	if len(weights) != len(t.Headers) {
		weights = make([]float64, len(t.Headers))
		for i := range weights {
			weights[i] = 1
		}
	}
	total := 0.0
	for _, x := range weights {
		total += x
	}
	widths := make([]float64, len(weights))
	for i, x := range weights {
		widths[i] = usableW * x / total
	}

	header := func() {
		pdf.SetFont("Helvetica", "B", 9)
		pdf.SetFillColor(30, 41, 59)
		pdf.SetTextColor(255, 255, 255)
		for i, h := range t.Headers {
			pdf.CellFormat(widths[i], 7, enc(h), "1", 0, "L", true, 0, "")
		}
		pdf.Ln(-1)
		pdf.SetFont("Helvetica", "", 8)
		pdf.SetTextColor(15, 23, 42)
	}
	// Repeat the column header after every page break — the manual ones below included, because
	// AddPage on a later page routes the page's start through this function.
	pdf.SetHeaderFunc(func() {
		if pdf.PageNo() == 1 {
			return
		}
		header()
	})
	pdf.SetFooterFunc(func() {
		pdf.SetY(-12)
		pdf.SetFont("Helvetica", "", 7)
		pdf.SetTextColor(100, 116, 139)
		pdf.CellFormat(0, 6, fmt.Sprintf("Page %d", pdf.PageNo()), "", 0, "C", false, 0, "")
	})

	// The institution's logo from the embedded brand.json, when it is a raster data-URL fpdf can
	// actually draw. Probed on a throwaway instance first so a corrupt logo can never poison the
	// real document — the letterhead degrades to text-only and the report still ships.
	logoOK := false
	if data, imageType, ok := brandLogoPNG(); ok {
		probe := fpdf.New("L", "mm", "A4", "")
		probe.RegisterImageOptionsReader("inst_logo",
			fpdf.ImageOptions{ImageType: imageType, ReadDpi: false}, bytes.NewReader(data))
		if probe.Error() == nil {
			pdf.RegisterImageOptionsReader("inst_logo",
				fpdf.ImageOptions{ImageType: imageType, ReadDpi: false}, bytes.NewReader(data))
			logoOK = true
		}
	}

	pdf.AddPage()
	const logoSize = 22.0
	titleX := margin
	titleY := 15.0
	if logoOK {
		// ImageOptions{} here means preserve the registered layout (a portrait 1:1 square); the
		// 0/"" width/height pair lets fpdf honour it. Give the logo the same banded square the
		// letterhead title spans, so a banner-shaped logo does not stretch the layout.
		pdf.ImageOptions("inst_logo", margin, titleY, logoSize, logoSize, false,
			fpdf.ImageOptions{}, 0, "")
		titleX = margin + logoSize + 6
	}
	pdf.SetXY(titleX, titleY+1)
	pdf.SetFont("Helvetica", "B", 15)
	pdf.SetTextColor(15, 23, 42)
	title := t.Title
	if institution != "" {
		title = institution + " — " + t.Title
	}
	pdf.CellFormat(0, 8, enc(title), "", 1, "L", false, 0, "")
	pdf.SetX(titleX)
	pdf.SetFont("Helvetica", "", 9)
	pdf.SetTextColor(100, 116, 139)
	sub := t.Subtitle
	if sub != "" {
		sub += " · "
	}
	pdf.CellFormat(0, 5, enc(sub+"Generated "+clock.Now().Format("2006-01-02 15:04")), "", 1, "L", false, 0, "")
	pdf.Ln(3)

	header()
	const rowH = 6.0
	for i, row := range t.Rows {
		// Wrap, never clip. The old loop trimmed a long cell one byte at a time until it fit,
		// which is how a printed report lost the tail of exactly the finding it was printed for.
		// Every cell now measures its own wrapped lines in the SAME font the row will print in,
		// the row grows to the tallest cell, MultiCell lays each cell's lines in place, and the
		// banded grid is drawn as rectangles around the finished row — nothing is cut.
		cellText := make([]string, len(t.Headers))
		colLines := make([]int, len(t.Headers))
		maxLines := 1
		for j := range t.Headers {
			if j < len(row) {
				cellText[j] = enc(row[j])
			}
			colLines[j] = len(pdf.SplitLines([]byte(cellText[j]), widths[j]-2))
			if colLines[j] > maxLines {
				maxLines = colLines[j]
			}
		}
		rowFullH := rowH * float64(maxLines)
		if pdf.GetY()+rowFullH > pageH-bottom {
			// The whole row advances to a fresh page, header printed; a row is never split.
			// (SetAutoPageBreak(true, bottom) still guards the theoretical over-tall row.)
			pdf.AddPage()
		}
		rowY := pdf.GetY()
		if i%2 == 0 {
			pdf.SetFillColor(248, 250, 252)
		} else {
			pdf.SetFillColor(255, 255, 255)
		}
		x := margin
		for j := range t.Headers {
			pdf.Rect(x, rowY, widths[j], rowFullH, "F")
			pdf.Rect(x, rowY, widths[j], rowFullH, "D")
			x += widths[j]
		}
		x = margin
		pdf.SetTextColor(15, 23, 42)
		for j := range t.Headers {
			pdf.SetXY(x, rowY)
			pdf.MultiCell(widths[j], rowH, cellText[j], "", "L", false)
			x += widths[j]
		}
		pdf.SetXY(margin, rowY+rowFullH)
	}
	if len(t.Rows) == 0 {
		pdf.SetFont("Helvetica", "I", 9)
		pdf.SetTextColor(100, 116, 139)
		pdf.CellFormat(0, 8, enc("No records match the selected filters."), "", 1, "L", false, 0, "")
	}

	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, filename))
	_ = pdf.Output(w)
}

// brandLogoPNG returns the institution logo from the embedded brand.json as raw image bytes plus
// the fpdf ImageType ("png"/"jpg"), or ok=false when there is none fpdf can draw: no logo, an
// https URL (the PDF builder runs server-side and won't fetch the network), webp/gif, or a
// base64 payload that fails to decode. Whitespace between the prefix and payload is ignored.
func brandLogoPNG() (data []byte, imageType string, ok bool) {
	bf := brandFile()
	if bf == nil {
		return nil, "", false
	}
	for _, p := range []struct{ prefix, typ string }{
		{"data:image/png;base64,", "png"},
		{"data:image/jpeg;base64,", "jpg"},
		{"data:image/jpg;base64,", "jpg"},
	} {
		if !strings.HasPrefix(bf.LogoURL, p.prefix) {
			continue
		}
		raw := strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}, strings.TrimPrefix(bf.LogoURL, p.prefix))
		decoded, err := base64.StdEncoding.DecodeString(raw)
		if err != nil || len(decoded) == 0 {
			return nil, "", false
		}
		return decoded, p.typ, true
	}
	return nil, "", false
}

// ─── Student attendance ───────────────────────────────────────────────────────

// GET /api/v1/dashboard/qa/student-attendance/export.{xlsx,csv,pdf}
func QAStudentAttendanceReport(pool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := middleware.GetTenantID(r.Context())
		// qaFiltersScoped, NOT qaFilters. This is the download of the table on screen, and the two
		// must be bounded identically: the JSON view has always applied the caller's own college or
		// department, and this took the unscoped filters. While only institution-wide offices could
		// reach the endpoint the difference was invisible — the moment a QA monitor or dept
		// rep was allowed to export, the button beneath their own college's table would have
		// handed them the whole institution's student record.
		list, err := queryStudentAttendance(r.Context(), pool, tenantID, qaFiltersScoped(r, pool))
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		t := reportTable{
			Title:    "Student Attendance",
			Subtitle: itoa(len(list)) + " student(s)",
			Headers:  []string{"Reg No.", "Name", "Course", "Level", "Session", "Year", "Sem", "Held", "Attended", "%"},
			Weights:  []float64{2.2, 3, 3.4, 1.4, 1.4, 0.7, 0.7, 0.8, 1, 0.9},
		}
		for _, s := range list {
			t.Rows = append(t.Rows, []string{
				s.StudentID, s.FullName, s.Course, s.Level, s.Session,
				itoa(s.Year), itoa(s.Semester), itoa(s.Held), itoa(s.Attended),
				formatFloat1(s.Percentage),
			})
		}
		writeReport(w, r, pool, format, "student-attendance", t)
	}
}

// ─── Lecturer attendance ──────────────────────────────────────────────────────

type lecturerSummaryExport struct {
	LecturerID        string  `json:"lecturer_id"`
	LecturerName      string  `json:"lecturer_name"`
	StaffID           string  `json:"staff_id"`
	Department        string  `json:"department"`
	Email             string  `json:"email"`
	TotalSessions     int     `json:"total_sessions"`
	TotalContactHours float64 `json:"total_contact_hours"`
	AvgContactHours   float64 `json:"avg_contact_hours"`
	LastSessionDate   string  `json:"last_session_date"`
}

func lecturerAttendanceTable(w http.ResponseWriter, r *http.Request, pool *pgxpool.Pool) (reportTable, bool) {
	body, ok := captureJSON(LecturerAttendanceSummaryForCaller(pool), w, r)
	if !ok {
		return reportTable{}, false
	}
	var rows []lecturerSummaryExport
	if err := json.Unmarshal(body, &rows); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
		return reportTable{}, false
	}
	t := reportTable{
		Title:    "Lecturer Attendance",
		Subtitle: fmt.Sprintf("%d lecturer(s)", len(rows)),
		Headers:  []string{"Lecturer", "Staff ID", "Department", "Email", "Sessions", "Total hrs", "Avg hrs", "Last session"},
		Weights:  []float64{2.6, 1.6, 2.4, 2.6, 1.1, 1.2, 1.1, 1.5},
	}
	for _, s := range rows {
		t.Rows = append(t.Rows, []string{
			s.LecturerName, s.StaffID, s.Department, s.Email, itoa(s.TotalSessions),
			fmt.Sprintf("%.1f", s.TotalContactHours), fmt.Sprintf("%.1f", s.AvgContactHours),
			s.LastSessionDate,
		})
	}
	return t, true
}

// GET /api/v1/dashboard/lecturer-attendance/export.{xlsx,csv,pdf}
func LecturerAttendanceExport(pool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if t, ok := lecturerAttendanceTable(w, r, pool); ok {
			writeReport(w, r, pool, format, "lecturer-attendance", t)
		}
	}
}

// ─── Employee attendance ──────────────────────────────────────────────────────

type employeeReportExport struct {
	From string `json:"from"`
	To   string `json:"to"`
	Rows []struct {
		StaffID  string `json:"staff_id"`
		Title    string `json:"title"`
		FullName string `json:"full_name"`
		Contact  string `json:"contact"`
		Comment  string `json:"comment"`
	} `json:"rows"`
}

func employeeAttendanceTable(w http.ResponseWriter, r *http.Request, adminPool *pgxpool.Pool) (reportTable, bool) {
	body, ok := captureJSON(EmployeeAttendanceReport(adminPool), w, r)
	if !ok {
		return reportTable{}, false
	}
	var rep employeeReportExport
	if err := json.Unmarshal(body, &rep); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
		return reportTable{}, false
	}
	t := reportTable{
		Title:    "Employee Attendance",
		Subtitle: fmt.Sprintf("%s to %s · %d employee(s)", rep.From, rep.To, len(rep.Rows)),
		Headers:  []string{"Staff ID", "Title", "Name", "Contact", "Comment"},
		Weights:  []float64{1.8, 1, 2.8, 2.4, 7},
	}
	for _, e := range rep.Rows {
		t.Rows = append(t.Rows, []string{e.StaffID, e.Title, e.FullName, e.Contact, e.Comment})
	}
	return t, true
}

// GET /api/v1/admin/tenants/{tenant_id}/employee-attendance/export.{xlsx,csv,pdf}
func EmployeeAttendanceExport(adminPool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if t, ok := employeeAttendanceTable(w, r, adminPool); ok {
			writeReport(w, r, adminPool, format, "employee-attendance", t)
		}
	}
}

// ─── Lecturer teaching (QA patrols) ───────────────────────────────────────────

type teachingReportExport struct {
	Rows []struct {
		LecturerID string `json:"lecturer_id"`
		Name       string `json:"full_name"`
		Department string `json:"department"`
		School     string `json:"school"`
		Taught     int    `json:"taught"`
		Patrolled  int    `json:"patrolled"`
	} `json:"rows"`
	TotalTaught    int `json:"total_taught"`
	TotalPatrolled int `json:"total_patrolled"`
}

func teachingReportTable(w http.ResponseWriter, r *http.Request, pool *pgxpool.Pool) (reportTable, bool) {
	body, ok := captureJSON(LecturerTeachingReport(pool), w, r)
	if !ok {
		return reportTable{}, false
	}
	var rep teachingReportExport
	if err := json.Unmarshal(body, &rep); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
		return reportTable{}, false
	}
	pct := func(a, b int) string {
		if b == 0 {
			return "—"
		}
		return fmt.Sprintf("%.0f%%", float64(a)/float64(b)*100)
	}
	t := reportTable{
		Title: "Lecturer Teaching (QA monitor rollup)",
		Subtitle: fmt.Sprintf("%d lecturer(s) · %d of %d monitor visits found teaching (%s)",
			len(rep.Rows), rep.TotalTaught, rep.TotalPatrolled, pct(rep.TotalTaught, rep.TotalPatrolled)),
		Headers: []string{"Lecturer", "Staff ID", "Department", "School", "Taught", "Monitored", "Rate"},
		Weights: []float64{3, 2, 2.6, 2.6, 1, 1.2, 1},
	}
	for _, l := range rep.Rows {
		name := l.Name
		if name == "" {
			name = l.LecturerID
		}
		t.Rows = append(t.Rows, []string{
			name, l.LecturerID, l.Department, l.School,
			itoa(l.Taught), itoa(l.Patrolled), pct(l.Taught, l.Patrolled),
		})
	}
	return t, true
}

// GET /api/v1/reports/lecturer-teaching/export.{xlsx,csv,pdf}
func LecturerTeachingExport(pool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if t, ok := teachingReportTable(w, r, pool); ok {
			writeReport(w, r, pool, format, "lecturer-teaching", t)
		}
	}
}

// ─── Employee daily sheet (the biometric terminal's 29-column export) ─────────

type employeeDaysExport struct {
	Days []employeeDay `json:"days"`
}

// employeeDaysTable renders whatever the CURRENT filters selected, not the whole
// institution. That is the point of it: the request was for reports on a specific
// filter, and captureJSON re-invokes the on-screen handler with the same query
// string, so the export can never disagree with the table it was clicked from.
func employeeDaysTable(w http.ResponseWriter, r *http.Request, pool *pgxpool.Pool) (reportTable, bool) {
	body, ok := captureJSON(EmployeeDays(pool), w, r)
	if !ok {
		return reportTable{}, false
	}
	var rep employeeDaysExport
	if err := json.Unmarshal(body, &rep); err != nil {
		writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
		return reportTable{}, false
	}

	// The filters, spelled back into the subtitle. A printed report that does not say
	// what it was narrowed to is indistinguishable from one covering everybody, which
	// is exactly the misreading that matters when it reaches a VC's desk.
	q := r.URL.Query()
	var narrowed []string
	if v := q.Get("department"); v != "" {
		narrowed = append(narrowed, v)
	}
	if v := q.Get("q"); v != "" {
		narrowed = append(narrowed, "matching "+v)
	}
	for _, f := range []struct{ key, label string }{
		{"late", "late arrivals"}, {"early", "early departures"},
		{"absent", "absences"}, {"exception", "exceptions"},
	} {
		if q.Get(f.key) == "true" {
			narrowed = append(narrowed, f.label)
		}
	}
	scope := "all staff"
	if len(narrowed) > 0 {
		scope = strings.Join(narrowed, " · ")
	}
	period := "all dates"
	if from, to := q.Get("from"), q.Get("to"); from != "" || to != "" {
		period = strings.TrimSpace(from + " to " + to)
	}

	t := reportTable{
		Title:    "Employee Attendance",
		Subtitle: fmt.Sprintf("%s · %s · %d row(s)", period, scope, len(rep.Days)),
		Headers: []string{"AC-No.", "Name", "Department", "Date", "On duty", "Off duty",
			"Clock In", "Clock Out", "Late", "Early", "Absent", "OT", "Work time"},
		Weights: []float64{1.2, 3, 2.6, 1.4, 1, 1, 1.1, 1.1, 0.9, 0.9, 0.9, 1, 1.2},
	}
	for _, d := range rep.Days {
		t.Rows = append(t.Rows, []string{
			d.ACNo, d.FullName, d.Department, d.WorkDate, d.OnDuty, d.OffDuty,
			d.ClockIn, d.ClockOut,
			flagCell(d.LateFlag), flagCell(d.EarlyFlag), flagCell(d.Absent),
			d.OTTime, d.WorkTime,
		})
	}
	return t, true
}

// flagCell renders an exception flag the way the source sheet does: "Yes" when it
// applies and BLANK when it does not, rather than "no". A column of the word "no"
// buries the handful of rows anyone is actually looking for. (Distinct from the
// yesNo in rooms.go, which is a genuine yes/no.)
func flagCell(b bool) string {
	if b {
		return "Yes"
	}
	return ""
}

// GET /api/v1/dashboard/employee-days/export.{xlsx,csv,pdf}
func EmployeeDaysExport(pool *pgxpool.Pool, format string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if t, ok := employeeDaysTable(w, r, pool); ok {
			writeReport(w, r, pool, format, "employee-attendance", t)
		}
	}
}
