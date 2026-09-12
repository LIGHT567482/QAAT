package handlers

import (
	"strings"
	"testing"
)

// absentSessionText is pure, so the wording ships with a check that the "no check-in" claim
// stays tied to the session it belongs to and the correction route stays the coordinator's.
func TestAbsentSessionText(t *testing.T) {
	subject, body := absentSessionText("Advanced Databases", "09:00")

	if !strings.Contains(subject, "Advanced Databases") {
		t.Errorf("subject = %q, want the unit name", subject)
	}
	if !strings.Contains(body, "has closed") {
		t.Errorf("body = %q, want the close claim", body)
	}
	if !strings.Contains(body, "no check-in") {
		t.Errorf("body = %q, want the no-check-in claim", body)
	}
	if !strings.Contains(body, "09:00") {
		t.Errorf("body = %q, want the session time", body)
	}
	if !strings.Contains(body, "course coordinator") {
		t.Errorf("body = %q, want the coordinator correction route", body)
	}
}

func TestAbsentSessionTextOmitsBlankTime(t *testing.T) {
	_, body := absentSessionText("Advanced Databases", "  ")
	if strings.Contains(body, "at  ") {
		t.Errorf("body = %q, must not show a blank time", body)
	}
}
