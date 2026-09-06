package checkin

import (
	"math"
	"strings"
	"testing"
	"time"
)

// The session U-Panel actually recorded, used as the fixture so the maths is checked against real
// coordinates rather than invented ones.
func upanelSession() SessionGeo {
	return SessionGeo{
		Lat: 0.2864366389306975, Lon: 32.60271793180766,
		RadiusMeters: 1500, HasLocation: true,
		Start: time.Date(2026, 8, 22, 15, 52, 54, 0, time.UTC),
		End:   time.Date(2026, 8, 22, 16, 7, 54, 0, time.UTC),
	}
}

func at(h, m int) time.Time { return time.Date(2026, 8, 22, h, m, 0, 0, time.UTC) }

// The real student check-in from U-Panel's export must be accepted, or QAAT and U-Panel would
// disagree about a record they both hold.
func TestVerify_AcceptsTheRealUPanelCheckin(t *testing.T) {
	v := VerifyCheckin(upanelSession(), 0.2856829294437984, 32.60276826169946, at(15, 53))
	if !v.OK {
		t.Fatalf("the real recorded check-in was rejected: %+v", v)
	}
	if v.Distance > 200 {
		t.Errorf("distance %dm looks wrong for two points ~85m apart", v.Distance)
	}
}

// Haversine against a known answer: one degree of latitude is ~111.19 km anywhere on the globe.
func TestDistance_MatchesKnownGeometry(t *testing.T) {
	d := DistanceMeters(0, 0, 1, 0)
	if math.Abs(d-111194.9) > 50 {
		t.Errorf("one degree of latitude measured %.1fm, expected ~111195m", d)
	}
	if DistanceMeters(0.1, 32.5, 0.1, 32.5) != 0 {
		t.Error("the same point is not zero metres from itself")
	}
}

// The boundary is where a rule is argued about, so it is where it must be exact.
func TestVerify_BoundaryIsInclusive(t *testing.T) {
	s := upanelSession()
	// ~1490m north of centre: one degree of latitude is 111194.9m, so 0.0134 degrees ≈ 1490m.
	inside := s.Lat + 0.0134
	if v := VerifyCheckin(s, inside, s.Lon, at(15, 55)); !v.OK {
		t.Errorf("a student %dm out was rejected inside a %dm radius", v.Distance, s.RadiusMeters)
	}
	// ~1668m north — clearly outside.
	outside := s.Lat + 0.0150
	v := VerifyCheckin(s, outside, s.Lon, at(15, 55))
	if v.OK {
		t.Errorf("a student %dm out was accepted inside a %dm radius", v.Distance, s.RadiusMeters)
	}
	if v.Distance == 0 {
		t.Error("a rejection must still report the distance, or it cannot be disputed")
	}
}

// Late is the commonest rejection and needs the message that explains itself.
func TestVerify_WindowIsEnforcedAndExplained(t *testing.T) {
	s := upanelSession()
	early := VerifyCheckin(s, s.Lat, s.Lon, at(15, 40))
	if early.OK || !strings.Contains(early.Reason, "not open yet") {
		t.Errorf("before the window: %+v", early)
	}
	late := VerifyCheckin(s, s.Lat, s.Lon, at(16, 30))
	if late.OK || !strings.Contains(late.Reason, "closed") {
		t.Errorf("after the window: %+v", late)
	}
}

// A phone with no fix sends 0,0 — a real place in the Gulf of Guinea, about 3,700km from Kampala.
// Measuring it as a distance would reject a present student for their handset's failure.
func TestVerify_NullIslandIsTreatedAsNoFixNotAsAPlace(t *testing.T) {
	v := VerifyCheckin(upanelSession(), 0, 0, at(15, 55))
	if v.OK {
		t.Error("0,0 was accepted as a location")
	}
	if !strings.Contains(v.Reason, "did not report a location") {
		t.Errorf("a student with no GPS was told %q, which does not tell them what to fix", v.Reason)
	}
}

// A lecturer whose phone could not get a fix must not mark a whole hall absent.
func TestVerify_SessionWithNoFixFallsBackToCodeAndWindow(t *testing.T) {
	s := upanelSession()
	s.HasLocation = false
	if v := VerifyCheckin(s, 0.5, 33.0, at(15, 55)); !v.OK {
		t.Errorf("a session opened without GPS rejected a student: %+v", v)
	}
	if v := VerifyCheckin(s, 0.5, 33.0, at(16, 30)); v.OK {
		t.Error("a session opened without GPS still must not accept after it closed")
	}
}

func TestSessionCode_ShapeAndAlphabet(t *testing.T) {
	seen := map[string]int{}
	for i := 0; i < 400; i++ {
		c, err := NewSessionCode(4)
		if err != nil {
			t.Fatalf("generate: %v", err)
		}
		if len(c) != 4 {
			t.Fatalf("expected 4 characters, got %q", c)
		}
		for _, ch := range c {
			if !strings.ContainsRune(sessionCodeAlphabet, ch) {
				t.Fatalf("%q contains %q, which is not in the spoken-safe alphabet", c, ch)
			}
		}
		seen[c]++
	}
	// Not a randomness test — a canary for a generator stuck on one value.
	if len(seen) < 100 {
		t.Errorf("400 codes produced only %d distinct values", len(seen))
	}
}

// The characters most often confused when a code is read aloud must not be in it at all.
func TestSessionCode_OmitsCharactersThatSoundOrLookAlike(t *testing.T) {
	for _, ch := range []string{"I", "1", "O", "0", "S", "5", "Z", "2"} {
		if strings.Contains(sessionCodeAlphabet, ch) {
			t.Errorf("%q is in the alphabet but is routinely misheard or mistyped", ch)
		}
	}
}

func TestNormaliseSessionCode_HandlesHowPeopleActuallyType(t *testing.T) {
	for _, in := range []string{"g60m", " G60M ", "g 6 0 m", "G60M\n"} {
		if got := NormaliseSessionCode(in); got != "G60M" {
			t.Errorf("%q normalised to %q, want %q", in, got, "G60M")
		}
	}
}
