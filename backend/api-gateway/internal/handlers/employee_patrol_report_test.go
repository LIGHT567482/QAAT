package handlers

// The office round's download.
//
// officeRoundTable takes []officeVisit rather than an *http.Request precisely so it can be checked
// here: there is no database harness in this package, and a table builder that needs a request is
// a table builder nothing verifies. The two things worth verifying are that the geometry holds
// (a Headers/Weights/Rows mismatch silently truncates a PDF column, with no error anywhere) and
// that a verdict renders as what was SEEN rather than as the enum.

import (
	"strings"
	"testing"
)

func fixtureVisits() []officeVisit {
	return []officeVisit{
		{
			VisitID: "1", StaffID: "KIU/044", EmployeeName: "A. Nakato", Department: "Finance",
			JobTitle: "Bursar", Office: "Block C, Room 14", OfficeSource: "REGISTRY",
			Status: "AT_OFFICE", VisitDate: "2026-09-03", VisitTime: "09:02",
			QAMonitor: "J. Okello", QAMonitorStaffID: "QA/07",
			CapturedAt: "2026-09-03T09:02:00Z", ReceivedAt: "2026-09-03T11:40:00Z",
		},
		{
			VisitID: "2", StaffID: "KIU/091", EmployeeName: "B. Mugisha", Department: "ICT",
			JobTitle: "Systems Officer", Office: "Annex, Room 3", OfficeSource: "TYPED",
			Status: "ELSEWHERE_ON_DUTY", FoundAt: "Server room", Remarks: "Network fault",
			VisitDate: "2026-09-03", VisitTime: "10:20",
			QAMonitor: "J. Okello", QAMonitorStaffID: "QA/07",
			CapturedAt: "2026-09-03T10:20:00Z", ReceivedAt: "2026-09-03T11:40:00Z",
		},
		{
			VisitID: "3", StaffID: "KIU/112", EmployeeName: "C. Auma", Department: "Library",
			Office: "Library office", OfficeSource: "REGISTRY",
			Status: "ABSENT", VisitDate: "2026-09-03", VisitTime: "11:05",
			QAMonitor: "J. Okello", QAMonitorStaffID: "QA/07",
			CapturedAt: "2026-09-03T11:05:00Z", ReceivedAt: "2026-09-03T11:40:00Z",
		},
	}
}

func TestOfficeRoundTableIsWellFormed(t *testing.T) {
	tbl := officeRoundTable(fixtureVisits())

	if len(tbl.Headers) != len(tbl.Weights) {
		t.Fatalf("%d headers but %d weights — the PDF writer pairs them positionally",
			len(tbl.Headers), len(tbl.Weights))
	}
	if len(tbl.Rows) != 3 {
		t.Fatalf("got %d rows, want 3", len(tbl.Rows))
	}
	for i, row := range tbl.Rows {
		if len(row) != len(tbl.Headers) {
			t.Errorf("row %d has %d cells, want %d — the extra ones are dropped silently",
				i, len(row), len(tbl.Headers))
		}
	}
	if !strings.Contains(tbl.Subtitle, "3") {
		t.Errorf("subtitle does not say how many visits: %q", tbl.Subtitle)
	}
}

func TestOfficeRoundTableRendersForAReader(t *testing.T) {
	tbl := officeRoundTable(fixtureVisits())
	joined := func(row []string) string { return strings.Join(row, "|") }

	// ABSENT must read as what was seen. "Absent" is a larger claim than one knock supports,
	// and this row leaves the building as a spreadsheet.
	if got := joined(tbl.Rows[2]); !strings.Contains(got, "Office empty") {
		t.Errorf("ABSENT did not render as 'Office empty': %s", got)
	}
	if got := joined(tbl.Rows[2]); strings.Contains(got, "ABSENT") || strings.Contains(got, "Absent") {
		t.Errorf("ABSENT leaked the enum or overstated the finding: %s", got)
	}
	if got := joined(tbl.Rows[0]); !strings.Contains(got, "At their office") {
		t.Errorf("AT_OFFICE did not render for a reader: %s", got)
	}
	if got := joined(tbl.Rows[1]); !strings.Contains(got, "Elsewhere, on duty") {
		t.Errorf("ELSEWHERE_ON_DUTY did not render for a reader: %s", got)
	}

	// A typed office is the registry telling on itself; it must survive into the download.
	if got := joined(tbl.Rows[1]); !strings.Contains(got, "Typed") {
		t.Errorf("office_source TYPED is missing from the row: %s", got)
	}
	if got := joined(tbl.Rows[0]); !strings.Contains(got, "Registry") {
		t.Errorf("office_source REGISTRY is missing from the row: %s", got)
	}

	// Every row names the observer. An observation with no observer on it is not evidence.
	for i, row := range tbl.Rows {
		if !strings.Contains(joined(row), "J. Okello") {
			t.Errorf("row %d does not name the QA monitor: %s", i, joined(row))
		}
	}
}

func TestOfficeStatusLabelPassesThroughTheUnknown(t *testing.T) {
	// A status added to the CHECK constraint but not here must show as itself rather than as
	// an empty cell that reads like "nothing was found".
	if got := officeStatusLabel("ON_LEAVE"); got != "ON_LEAVE" {
		t.Errorf("officeStatusLabel(%q) = %q, want the value back", "ON_LEAVE", got)
	}
}

func TestOfficeRoundTableWithNoVisits(t *testing.T) {
	tbl := officeRoundTable(nil)
	if len(tbl.Rows) != 0 {
		t.Errorf("got %d rows for an empty round, want 0", len(tbl.Rows))
	}
	if len(tbl.Headers) == 0 {
		t.Error("an empty round must still produce a headed sheet, not a blank file")
	}
}
