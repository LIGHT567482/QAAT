package handlers

// What an employee is allowed to read when their office was found empty.
//
// Three rules, pinned here rather than left to whoever next edits the format string:
//
//   - it must say WHICH DOOR and WHEN, or the person cannot answer it at all
//   - it must NOT name the monitor — the observation belongs to quality assurance, and naming the
//     individual turns a record into one colleague accusing another (see patrolSenderName)
//   - it must NOT state a verdict — one knock establishes that a door was empty at a minute, not
//     that somebody was absent from work, and this recipient has no dashboard on which to argue
//
// The last two are satisfied by an ABSENCE from the text, which is exactly what a later edit
// restores without noticing. That is what makes them worth a test and the first one nearly not.

import (
	"strings"
	"testing"
)

func TestOfficeAbsenceMessageNamesNoMonitor(t *testing.T) {
	// A monitor is in scope at the call site — patroller_name is on the row and the QA reports
	// read it. None of it may reach the person the visit is about.
	subject, body := officeAbsenceMessage("Block C, Room 14", "2026-09-03", "10:14")
	text := strings.ToLower(subject + "\n" + body)

	for _, forbidden := range []string{
		"jane doe", "monitor:", "observed by", "recorded by", "patroller", "reported by",
	} {
		if strings.Contains(text, forbidden) {
			t.Errorf("message names the observer (%q):\n%s\n%s", forbidden, subject, body)
		}
	}
}

func TestOfficeAbsenceMessageSaysWhichDoorAndWhen(t *testing.T) {
	subject, body := officeAbsenceMessage("Block C, Room 14", "2026-09-03", "10:14")

	if !strings.Contains(body, "Block C, Room 14") {
		t.Errorf("message does not say which office:\n%s", body)
	}
	// lectureWhen renders "Thu 3 Sep 2026 at 10:14"; assert on the parts, so a change to its
	// format is not a failure here.
	for _, want := range []string{"2026", "10:14"} {
		if !strings.Contains(subject+body, want) {
			t.Errorf("message does not say when (missing %q):\n%s\n%s", want, subject, body)
		}
	}
}

func TestOfficeAbsenceMessageIsNotAVerdict(t *testing.T) {
	subject, body := officeAbsenceMessage("Block C, Room 14", "2026-09-03", "10:14")
	text := strings.ToLower(subject + "\n" + body)

	const disclaimer = "not a finding that you were absent from work"

	// The clauses that make this a record rather than a charge. Both are one careless rewrite
	// away at all times, so they are asserted before anything else — the scan below depends on
	// the first one being present to know what to discount.
	if !strings.Contains(text, disclaimer) {
		t.Fatalf("message dropped the 'this is not a finding' clause:\n%s", body)
	}

	// Now the assertions the visit cannot support. The disclaimer is REMOVED first: it contains
	// "you were absent" by construction, and a scan that flagged it would be flagging the one
	// sentence keeping the message honest. What is left must contain none of these.
	claims := strings.ReplaceAll(text, disclaimer, "")
	for _, forbidden := range []string{
		"you were absent", "you did not", "failure to", "unauthorised", "unauthorized",
		"absent from duty", "you were not at", "disciplinary",
	} {
		if strings.Contains(claims, forbidden) {
			t.Errorf("message states a verdict the visit does not support (%q):\n%s", forbidden, body)
		}
	}

	if !strings.Contains(text, "read together") {
		t.Errorf("message dropped the 'filed beside the terminal record' clause:\n%s", body)
	}
	if !strings.Contains(text, "head of department") {
		t.Errorf("message leaves the person nowhere to answer:\n%s", body)
	}
}

func TestOfficeAbsenceMessageWithoutAKnownOffice(t *testing.T) {
	// The registry does not always know the door, and the monitor may not have typed one. The
	// message must still be about something.
	_, body := officeAbsenceMessage("", "2026-09-03", "10:14")
	if !strings.Contains(body, "your office") {
		t.Errorf("message with no office does not degrade to a readable sentence:\n%s", body)
	}
	if strings.Contains(body, "called at  on") {
		t.Errorf("message with no office leaves a hole in the sentence:\n%s", body)
	}
}

func TestValidOfficeStatusMatchesTheCheckConstraint(t *testing.T) {
	// The three the migration's CHECK allows, and nothing else. Rejecting here as well as there
	// is what lets one bad row be skipped with the rest of the batch surviving.
	for _, ok := range []string{"AT_OFFICE", "ELSEWHERE_ON_DUTY", "ABSENT"} {
		if !validOfficeStatus(ok) {
			t.Errorf("validOfficeStatus(%q) = false, want true", ok)
		}
	}
	for _, bad := range []string{"", "absent", "PRESENT", "NOT_TAUGHT", "TRUE"} {
		if validOfficeStatus(bad) {
			t.Errorf("validOfficeStatus(%q) = true, want false", bad)
		}
	}
}
