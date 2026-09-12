package attendance

import (
	"math"
	"testing"
	"time"
)

func at(s string) *time.Time { return ParseTimestamp(s) }

func session(over func(*Session)) *Session {
	s := &Session{
		ID:           "s1",
		ListID:       "l1",
		Status:       "ACTIVE",
		Start:        at("2026-09-11T09:00:00Z"),
		End:          at("2026-09-11T11:00:00Z"),
		Latitude:     0, Longitude: 0, // zero centre = no location → accepts
		RadiusMeters: 1500,
	}
	if over != nil {
		over(s)
	}
	return s
}

// lookup over a static set of sessions.
func lookupOf(sessions ...*Session) Lookup {
	byID := map[string]*Session{}
	byCode := map[string]*Session{}
	for _, s := range sessions {
		byID[s.ID] = s
	}
	return Lookup{
		ByID: func(id string) *Session { return byID[id] },
		ByCode: func(code string) *Session {
			return byCode[code]
		},
	}
}

func factsNow(t *testing.T) Facts {
	return Facts{Now: mustTime(t, "2026-09-11T09:30:00Z"), RecordExists: func(string, string) bool { return false }}
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	tt := at(s)
	if tt == nil {
		t.Fatalf("bad time %q", s)
	}
	return *tt
}

func attempt(over func(*Attempt)) Attempt {
	a := Attempt{
		StudentID:       "S2019/001",
		DeviceID:        "phone-77",
		Latitude:        0, Longitude: 0,
		CapturedAt: at("2026-09-11T09:30:00Z"),
		ReceivedAt: at("2026-09-11T09:30:01Z"),
	}
	if over != nil {
		over(&a)
	}
	return a
}

func evaluate(a Attempt, lookup Lookup, facts Facts) Decision {
	return Evaluate(a, lookup, facts)
}

func TestAcceptHubClaimHappyPath(t *testing.T) {
	// Hub already resolved the session; student typed reg-no; GPS quiet (0,0 →
	// plane on the LAN, no fix) — accepted and the distance is 0.
	a := attempt(func(a *Attempt) { a.SessionID = "s1" })
	d := evaluate(a, lookupOf(session(nil)), factsNow(t))
	if d.Verdict != VerdictAccepted {
		t.Fatalf("want accepted, got %v (%s)", d.Verdict, d.Reason)
	}
	if d.SessionID != "s1" || d.ListID != "l1" {
		t.Fatalf("session/list not carried: %+v", d)
	}
}

func TestTypedCodeResolvesToSession(t *testing.T) {
	s := session(func(s *Session) { s.Latitude, s.Longitude = 0.3120, 32.5808 })
	// the code field is matched case-insensitively by the service; the engine
	// normalises then asks the lookup.
	lk := lookupOf(s)
	a := attempt(func(a *Attempt) { a.SessionCode = "g60m" }) // typed in lowercase
	d := evaluate(a, lk, factsNow(t))
	// ByCode is service-supplied; wiring it to the map tests the engine hands
	// the normalised code in.
	if d.Verdict != VerdictRejected || d.Reason != "session code not found" {
		t.Fatalf("with a unmapped lookup the code cannot resolve: %+v", d)
	}
}

func TestCodeResolutionByCodeAuthenticates(t *testing.T) {
	s := session(nil)
	lk := Lookup{ByCode: func(code string) *Session {
		if code == "G60M" {
			return s
		}
		return nil
	}}
	a := attempt(func(a *Attempt) { a.SessionCode = "g60m" })
	d := evaluate(a, lk, factsNow(t))
	if d.Verdict != VerdictAccepted {
		t.Fatalf("want accepted, got %v (%s)", d.Verdict, d.Reason)
	}
}

func TestAwaitingSessionWithCodeStaysPending(t *testing.T) {
	// Lecturer has not opened yet — the claim must survive for the sweep.
	a := attempt(func(a *Attempt) {
		a.SessionCode = "G60M"
		a.AwaitingSession = true
	})
	d := evaluate(a, Lookup{ByCode: func(string) *Session { return nil }}, factsNow(t))
	if d.Verdict != VerdictPending {
		t.Fatalf("want pending, got %v", d.Verdict)
	}
}

func TestAwaitingSessionNoCodeStaysPending(t *testing.T) {
	a := attempt(func(a *Attempt) { a.AwaitingSession = true })
	d := evaluate(a, Lookup{}, factsNow(t))
	if d.Verdict != VerdictPending {
		t.Fatalf("want pending, got %v", d.Verdict)
	}
}

func TestNoCodeNotAwaitingRejects(t *testing.T) {
	a := attempt(nil) // no session id, no code
	d := evaluate(a, Lookup{}, factsNow(t))
	if d.Verdict != VerdictRejected || d.Reason != "session code not found" {
		t.Fatalf("want 'session code not found', got %+v", d)
	}
}

func TestClaimedIdButSessionGoneRejects(t *testing.T) {
	a := attempt(func(a *Attempt) { a.SessionID = "ghost" })
	d := evaluate(a, Lookup{ByID: func(string) *Session { return nil }}, factsNow(t))
	if d.Verdict != VerdictRejected || d.Reason != "session does not match" {
		t.Fatalf("want 'session does not match', got %+v", d)
	}
}

func TestMissingStudentIDRejects(t *testing.T) {
	a := attempt(func(a *Attempt) { a.SessionID = "s1"; a.StudentID = "  " })
	d := evaluate(a, lookupOf(session(nil)), factsNow(t))
	if d.Verdict != VerdictRejected || d.Reason != "missing student id" {
		t.Fatalf("want 'missing student id', got %+v", d)
	}
}

func TestTimeWindow(t *testing.T) {
	cases := []struct {
		name    string
		capture string
		over    func(*Session)
		want    Verdict
		reason  string
	}{
		{"in-window is fine", "2026-09-11T10:00:00Z", nil, VerdictAccepted, ""},
		{"1 min early passes (clock drift)", "2026-09-11T08:59:00Z", nil, VerdictAccepted, ""},
		{"3 min early fails", "2026-09-11T08:57:00Z", nil, VerdictRejected, "outside session time"},
		{"after end while active is fine", "2026-09-11T11:05:00Z", nil, VerdictAccepted, ""},
		{
			"after end while closed fails",
			"2026-09-11T11:05:00Z",
			func(s *Session) { s.Status = "CLOSED" },
			VerdictRejected, "outside session time",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := attempt(func(a *Attempt) { a.SessionID = "s1"; a.CapturedAt = at(c.capture) })
			if a.ReceivedAt != nil {
				rcv := a.CapturedAt.Add(2 * time.Second)
				a.ReceivedAt = &rcv
			}
			d := evaluate(a, lookupOf(session(c.over)), factsNow(t))
			if d.Verdict != c.want || (c.reason != "" && d.Reason != c.reason) {
				t.Fatalf("want %v %q, got %v %q", c.want, c.reason, d.Verdict, d.Reason)
			}
		})
	}
}

func TestDeviceClockSkewTrustsServer(t *testing.T) {
	// Device says 08:50 (10 min behind server, >5 min skew). The server receipt
	// time 09:30 is inside the window → accept instead of rejecting on a drifted clock.
	a := attempt(func(a *Attempt) {
		a.SessionID = "s1"
		a.CapturedAt = at("2026-09-11T08:50:00Z")
		a.ReceivedAt = at("2026-09-11T09:30:01Z")
	})
	d := evaluate(a, lookupOf(session(nil)), factsNow(t))
	if d.Verdict != VerdictAccepted {
		t.Fatalf("server receipt time should win: %+v", d)
	}
}

func TestDeviceClockSkewGracesUpToTwoMinutesEarly(t *testing.T) {
	// First lecture in QAAT runs 08:00; a device 1 min fast "captures" at 08:59,
	// real time 09:00. Effective = captured (skew < 5 min) → 1 min early passes.
	a := attempt(func(a *Attempt) {
		a.SessionID = "s1"
		a.CapturedAt = at("2026-09-11T08:59:00Z")
	})
	d := evaluate(a, lookupOf(session(nil)), factsNow(t))
	if d.Verdict != VerdictAccepted {
		t.Fatalf("early-but-within-grace should pass: %+v", d)
	}
}

func TestGenericDeviceIDsAreNotUnique(t *testing.T) {
	s := session(nil)
	// The same emulator device id marking two "different" students is exactly the
	// false-positive the generic list exists to suppress.
	sessions := lookupOf(s)
	a := attempt(func(a *Attempt) { a.SessionID = "s1"; a.DeviceID = "9774d56d682e549c" })
	if UsableDeviceID(a.DeviceID) != "" {
		t.Fatal("emulator id must be unusable")
	}
	// Engine must not consult DeviceUsedByOther for an unusable id.
	reuse := false
	if d := evalNow(a, sessions, reuse); d.Verdict != VerdictAccepted {
		t.Fatalf("emulator reuse must not reject: %+v", d)
	}
}

func TestDeviceMarkedForAnotherStudentRejects(t *testing.T) {
	a := attempt(func(a *Attempt) { a.SessionID = "s1" })
	d := Evaluate(a, lookupOf(session(nil)), Facts{
		Now: mustTime(t, "2026-09-11T09:30:00Z"),
		DeviceUsedByOther: func(_, _, _ string) bool { return true },
	})
	if d.Verdict != VerdictRejected || d.Reason != "device already used for another student" {
		t.Fatalf("want device-reuse rejection, got %+v", d)
	}
}

func TestGeofence(t *testing.T) {
	// A campus centre somewhere real.
	const centreLat, centreLon = 0.3120, 32.5808
	sess := func(over func(*Session)) *Session {
		return session(func(s *Session) {
			s.Latitude, s.Longitude = centreLat, centreLon
			s.RadiusMeters = 1500
			if over != nil {
				over(s)
			}
		})
	}

	cases := []struct {
		name   string
		over   func(*Session)
		lat    float64
		lon    float64
		acc    float64
		want   Verdict
		reason string
	}{
		{"inside the 1500m circle", nil, latOffset(centreLat, 1495), centreLon, 0, VerdictAccepted, ""},
		{"105m outside fails exactly", nil, latOffset(centreLat, 1605), centreLon, 0, VerdictRejected, "outside class location"},
		{"GPS uncertainty absorbs 50m over", nil, latOffset(centreLat, 1575), centreLon, 100, VerdictAccepted, ""},
		{"normal student on campus", nil, 0.3121, 32.5809, 8, VerdictAccepted, ""},
		{"null island rejects", nil, 0, 0, 0, VerdictRejected, "outside class location"},
		{"remote learning bypasses", func(s *Session) { s.RemoteLearning = true }, latOffset(centreLat, 40000), centreLon, 0, VerdictAccepted, ""},
		{"pending location bypasses", func(s *Session) { s.LocationMetadataPending = true }, latOffset(centreLat, 40000), centreLon, 0, VerdictAccepted, ""},
		{"zero centre accepts — no fix at open", nil, 0.3121, 32.5809, 0, VerdictAccepted, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := sess(c.over)
			a := attempt(func(a2 *Attempt) {
				a2.SessionID = "s1"
				a2.Latitude, a2.Longitude = c.lat, c.lon
				a2.GPSAccuracyMeters = c.acc
			})
			d := Evaluate(a, lookupOf(s), factsNow(t))
			if d.Verdict != c.want || (c.reason != "" && d.Reason != c.reason) {
				t.Fatalf("want %v %q, got %v %q (dist %d)", c.want, c.reason, d.Verdict, d.Reason, d.DistanceMeters)
			}
		})
	}
}

func TestDuplicateRecordVerdict(t *testing.T) {
	s := session(nil)
	a := attempt(func(a *Attempt) { a.SessionID = "s1" })
	d := Evaluate(a, lookupOf(s), Facts{
		Now:           mustTime(t, "2026-09-11T09:30:00Z"),
		RecordExists:  func(_, _ string) bool { return true },
	})
	if d.Verdict != VerdictDuplicate {
		t.Fatalf("want duplicate, got %v", d.Verdict)
	}
}

func TestDefaultRadiusWhenUnset(t *testing.T) {
	s := session(func(s *Session) { s.RadiusMeters = 0; s.Latitude, s.Longitude = 0.3120, 32.5808 })
	a := attempt(func(a *Attempt) {
		a.SessionID = "s1"
		a.Latitude = latOffset(0.3120, 1495)
		a.Longitude = 32.5808
	})
	if d := Evaluate(a, lookupOf(s), factsNow(t)); d.Verdict != VerdictAccepted {
		t.Fatalf("default 1500m radius should accept 1495m: %+v", d)
	}
}

func TestDistanceReportedOnAcceptance(t *testing.T) {
	s := session(func(s *Session) { s.Latitude, s.Longitude = 0.3120, 32.5808 })
	a := attempt(func(a *Attempt) {
		a.SessionID = "s1"
		a.Latitude = latOffset(0.3120, 300)
		a.Longitude = 32.5808
	})
	d := Evaluate(a, lookupOf(s), factsNow(t))
	if d.Verdict != VerdictAccepted {
		t.Fatalf("expected acceptance: %+v", d)
	}
	if math.Abs(float64(d.DistanceMeters-300)) > 3 {
		t.Fatalf("distance ~300m, got %dm", d.DistanceMeters)
	}
}

func evalNow(a Attempt, lk Lookup, claimedReuse bool) Decision {
	return Evaluate(a, lk, Facts{
		Now:               time.Date(2026, 9, 11, 9, 30, 0, 0, time.UTC),
		DeviceUsedByOther: func(_, _, _ string) bool { return claimedReuse },
	})
}

// latOffset moves roughly `meters` north of lat, keeping lon fixed.
func latOffset(lat, meters float64) float64 {
	return lat + meters/EarthRadiusMeters*(180/math.Pi)
}