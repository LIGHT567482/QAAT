package handlers

// What a lecturer is allowed to read when the round recorded them as NOT TAUGHT.
//
// Three rules, pinned here rather than left to whoever next edits the strings (the office-round
// suite files the same three for its own reader):
//
//   - it must say WHICH lecture and WHEN — "recorded as NOT TAUGHT for Data Structures" says
//     nothing to a lecturer teaching the same unit to three cohorts, and ticks sync from phones
//     that may have been offline, so "today" is not a safe assumption either
//   - it must NOT name the monitor — the observation belongs to quality assurance, and naming the
//     individual turns a record into one colleague accusing another (see patrolSenderName)
//   - a NOT TAUGHT record must carry the WAY BACK — that clause is the difference between an
//     accusation and a piece of paper: the appeal (APPEAL_NOT_TAUGHT) pointed at this lecture
//
// Unlike the employee, the lecturer HAS an account and an inbox, so the message may plainly state
// the record AND may offer the answer within it — the "two accounts, read together" sentence is
// exactly the remedy the employee has to be told to take to their head of department.

import (
	"strings"
	"testing"
)

func TestVerdictMessageNamesNoMonitor(t *testing.T) {
	l := patrolLogIn{UnitID: "DSA101", UnitName: "Data Structures", CourseCode: "BSC-CS",
		LecturerID: "10001", LecturerName: "Jane Doe", Room: "LR3",
		SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: false}
	subject, body := verdictMessage(l)
	text := strings.ToLower(subject + "\n" + body)

	for _, forbidden := range []string{"jane doe", "monitor: jane", "observed by", "recorded by", "patroller"} {
		if strings.Contains(text, forbidden) {
			t.Errorf("message names the observer (%q):\n%s\n%s", forbidden, subject, body)
		}
	}
}

func TestVerdictMessageNotTaughtSaysWhichLectureAndWhen(t *testing.T) {
	l := patrolLogIn{UnitName: "Data Structures", CourseCode: "BSC-CS", Room: "LR3",
		SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: false}
	_, body := verdictMessage(l)

	for _, want := range []string{"Data Structures", "BSC-CS", "LR3", "2026", "14:00"} {
		if !strings.Contains(body, want) {
			t.Errorf("message omits %q:\n%s", want, body)
		}
	}
	// Two sittings of the same unit must NOT be indistinguishable in the message — the time is
	// what tells a Wednesday 8:00 sitting from a Wednesday 14:00 one.
	if !strings.Contains(body, "14:00") {
		t.Errorf("message does not say the time:\n%s", body)
	}
}

func TestVerdictMessageNotTaughtOffersTheAppeal(t *testing.T) {
	l := patrolLogIn{UnitName: "Data Structures", SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: false}
	_, body := verdictMessage(l)

	for _, want := range []string{"say so here", "two accounts", "does not overturn"} {
		if !strings.Contains(body, want) {
			t.Errorf("NOT TAUGHT record lost its remedy (%q):\n%s", want, body)
		}
	}
	if strings.Contains(body, "you are in trouble") || strings.Contains(body, "must explain") {
		t.Errorf("message reads as a charge rather than a record:\n%s", body)
	}
}

func TestVerdictMessageTaughtIsAConfirmationWithoutAppeal(t *testing.T) {
	l := patrolLogIn{UnitName: "Data Structures", SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: true}
	_, body := verdictMessage(l)

	if !strings.Contains(body, "TAUGHT") {
		t.Errorf("confirmation does not state what was recorded:\n%s", body)
	}
	// The confirmation must not drift into the accusation the absent record lives on — the
	// appeal sentence is that record's exclusive property.
	for _, forbidden := range []string{"say so here", "two accounts", "NOT TAUGHT"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("a TAUGHT confirmation borrows the accusation's words (%q):\n%s", forbidden, body)
		}
	}
}

func TestVerdictMessageDegradesWithoutCourseOrRoom(t *testing.T) {
	l := patrolLogIn{UnitName: "Data Structures", SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: false}
	_, body := verdictMessage(l)

	// No stray separators left by blanks — "(BSC-CS)" becomes "()", ", in " leaves a comma.
	for _, hole := range []string{"()", "on ,", "in ,", ", ,"} {
		if strings.Contains(body, hole) {
			t.Errorf("message left a hole (%q):\n%s", hole, body)
		}
	}
}

func TestPatrolAbsentEmailStillCarriesRecordAndWayBack(t *testing.T) {
	l := patrolLogIn{UnitName: "Data Structures", Room: "LR3",
		SessionDate: "2026-09-03", ScheduledTime: "14:00", Taught: false}
	subject, body := patrolAbsentEmail(l)

	// The email is the reader who is NOT looking at the app's inbox; "say so here" is a
	// tap-through that only exists there. The email must say WHERE the appeal lives — or a
	// lecturer who got a letter has still been handed a dead end.
	if strings.Contains(body, "say so here") {
		t.Errorf("email keeps the app-only tap-through words:\n%s", body)
	}
	if !strings.Contains(subject, "QA monitor:") {
		t.Errorf("email subject does not say who the record is from:\n%s", subject)
	}
	if !strings.Contains(body, "KIU QAAT app where this alert found you") {
		t.Errorf("email lost the pointer to the appeal:\n%s", body)
	}
	if !strings.Contains(body, "two accounts") {
		t.Errorf("email lost the 'filed beside the monitor' clause:\n%s", body)
	}
	if !strings.Contains(body, "14:00") || !strings.Contains(body, "Data Structures") {
		t.Errorf("email does not say which lecture and when:\n%s", body)
	}
}
