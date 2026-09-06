package upanel

import "testing"

// index builds an orgIndex without a database, so the matching RULES can be tested apart from the
// queries that populate them. The rules are where the judgement lives.
func index() *orgIndex {
	ix := &orgIndex{
		byStudent: map[string]Resolution{}, byUnitID: map[string]Resolution{},
		byUnitName: map[string]Resolution{}, byCourse: map[string]Resolution{},
		byLecturer: map[string]Resolution{}, ambiguous: map[string]bool{},
	}
	put(ix.byStudent, ix.ambiguous, norm("2025-08-40174"), Resolution{"", "Computer Science", "SOMAC", "student", ""})
	put(ix.byUnitID, ix.ambiguous, norm("CSE 2420"), Resolution{"CSE 2420", "Computer Science", "SOMAC", "unit", ""})
	put(ix.byUnitName, ix.ambiguous, norm("Structured Programming"), Resolution{"CSE 2120", "Computer Science", "SOMAC", "unit", ""})
	put(ix.byCourse, ix.ambiguous, norm("Software Engineering"), Resolution{"", "Computer Science", "SOMAC", "course", ""})
	put(ix.byLecturer, ix.ambiguous, norm("BYAMUKAMA PETER"), Resolution{"", "Computer Science", "SOMAC", "lecturer", ""})
	return ix
}

// The registration number is institution-issued and identical in both systems, so it must win even
// when weaker signals are present and disagree.
func TestResolve_PrefersTheStudentIdOverTypedNames(t *testing.T) {
	r := index().Resolve(Record{
		StudentID: "2025-08-40174",
		Course:    "Something Else Entirely",
		Lecturer:  "Nobody At All",
	})
	if r.Via != "student" || r.Department != "Computer Science" {
		t.Fatalf("expected the student rule to win, got via=%q dept=%q", r.Via, r.Department)
	}
}

func TestResolve_FallsBackThroughUnitThenCourseThenLecturer(t *testing.T) {
	ix := index()
	for _, c := range []struct {
		name, via string
		rec       Record
	}{
		{"unit code", "unit", Record{Unit: "CSE 2420"}},
		{"unit name", "unit", Record{UnitName: "Structured Programming"}},
		{"course", "course", Record{Course: "Software Engineering"}},
		{"lecturer", "lecturer", Record{LecturerName: "BYAMUKAMA PETER"}},
	} {
		if got := ix.Resolve(c.rec); got.Via != c.via {
			t.Errorf("%s: expected via=%q, got %q (unresolved=%q)", c.name, c.via, got.Via, got.Unresolved)
		}
	}
}

// Spreadsheets and phone keyboards. The same unit typed with different case and spacing is the
// same unit, or the match rate collapses for reasons nobody can see.
func TestResolve_IgnoresCaseAndSpacing(t *testing.T) {
	r := index().Resolve(Record{UnitName: "  structured   PROGRAMMING "})
	if r.Department != "Computer Science" {
		t.Errorf("normalisation failed: %+v", r)
	}
}

// A lecturer teaching in two departments is normal and correct. Picking one would silently move
// attendance from one college's report into another's, which is worse than declining to guess.
func TestResolve_RefusesToGuessOnAnAmbiguousName(t *testing.T) {
	ix := index()
	put(ix.byLecturer, ix.ambiguous, norm("BYAMUKAMA PETER"), Resolution{"", "Nursing", "SOHS", "lecturer", ""})
	r := ix.Resolve(Record{LecturerName: "BYAMUKAMA PETER"})
	if r.Unresolved == "" {
		t.Errorf("an ambiguous lecturer was resolved to %q — it should decline instead", r.Department)
	}
}

// The reason is the feature: a naming mismatch must read as a fixable queue entry, never as an
// empty hall. It also has to name what was tried, or nobody can act on it.
func TestResolve_UnmatchedRowExplainsItself(t *testing.T) {
	r := index().Resolve(Record{UnitName: "Fundamentals of Programming", Course: "Unknown Course"})
	if r.Unresolved == "" {
		t.Fatal("an unmatched row must carry a reason, not resolve to nothing silently")
	}
	for _, want := range []string{"course=Unknown Course", "unit=Fundamentals of Programming"} {
		if !contains(r.Unresolved, want) {
			t.Errorf("reason %q does not mention %q", r.Unresolved, want)
		}
	}
}

// Same input, same words, every import — otherwise an unchanged problem looks new each time.
func TestResolve_ReasonIsStableAcrossRuns(t *testing.T) {
	rec := Record{UnitName: "Ghost Unit", Course: "Ghost Course", LecturerName: "Ghost", StudentID: "GHOST"}
	first := index().Resolve(rec).Unresolved
	for i := 0; i < 20; i++ {
		if got := index().Resolve(rec).Unresolved; got != first {
			t.Fatalf("reason changed between runs:\n  %q\n  %q", first, got)
		}
	}
}

func TestResolve_EmptyRecordSaysSo(t *testing.T) {
	r := index().Resolve(Record{})
	if r.Unresolved != "the record names no student, unit, course or lecturer" {
		t.Errorf("unexpected reason for an empty record: %q", r.Unresolved)
	}
}

func contains(hay, needle string) bool {
	return len(hay) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(hay); i++ {
			if hay[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}
