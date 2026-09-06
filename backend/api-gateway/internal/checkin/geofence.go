package checkin

import (
	"crypto/rand"
	"math"
	"strings"
	"time"
)

// U-PANEL'S PRESENCE MODEL: a spoken code, a circle on the map, and a time window.
//
// The lecturer opens a session; it gets a short code and remembers where it was opened. The student
// types the code and their phone sends its own coordinates. The check-in is accepted when the code
// matches a session that is still open and the phone is inside that session's circle.
//
// This replaces "you must be on the coordinator's hotspot" as the proof of presence. The two prove
// different things and it is worth being exact about the difference, because the numbers look
// similar and are not: the hotspot is a radio in the room, so reaching it means being in or beside
// the room. A 1500-metre circle — U-Panel's own value, and QAAT's default to match it — covers most
// of a campus. A student in the car park, in the next building, or asleep in a hall of residence
// across the road is inside it. What this checks, honestly stated, is that the phone was ON CAMPUS
// while the lecture was running.
//
// Everything here is deliberately free of I/O so the rules can be tested exactly, including the
// cases that are awkward to produce on a real handset: a student one metre outside the boundary, a
// check-in a second after the window closes, a phone reporting the null island.

// EarthRadiusMeters — mean radius. Haversine on a sphere is accurate to about 0.3% for distances of
// this size, which at 1500 metres is under five metres of error: far smaller than a phone's own GPS
// uncertainty, so a more elaborate ellipsoidal model would add precision the input does not have.
const EarthRadiusMeters = 6371000.0

// DefaultRadiusMeters matches the radiusMeters observed on U-Panel sessions.
const DefaultRadiusMeters = 1500

// DistanceMeters is the great-circle distance between two points.
func DistanceMeters(lat1, lon1, lat2, lon2 float64) float64 {
	toRad := func(d float64) float64 { return d * math.Pi / 180 }
	dLat := toRad(lat2 - lat1)
	dLon := toRad(lon2 - lon1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRad(lat1))*math.Cos(toRad(lat2))*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * EarthRadiusMeters * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// GeoVerdict is the outcome of one check-in attempt, with the distance kept whether it was accepted
// or not. A rejected student asking "but I was there" is answered by a number, not an opinion.
type GeoVerdict struct {
	OK       bool
	Distance int    // metres from the session centre, rounded
	Reason   string // empty when OK; otherwise what to tell the student
}

// SessionGeo is what a session knows about where and when it is open.
type SessionGeo struct {
	Lat, Lon     float64
	RadiusMeters int
	Start, End   time.Time
	HasLocation  bool // false when the session was opened without a fix
}

// VerifyCheckin decides one attempt.
//
// The order of the checks is chosen so the message a student sees is the most useful one available:
// being outside the window is told before being outside the circle, because a student who arrived
// late needs to know the register closed, not that they are standing in the wrong place.
func VerifyCheckin(s SessionGeo, lat, lon float64, now time.Time) GeoVerdict {
	if !s.Start.IsZero() && now.Before(s.Start) {
		return GeoVerdict{Reason: "this register is not open yet"}
	}
	if !s.End.IsZero() && now.After(s.End) {
		return GeoVerdict{Reason: "this register has closed"}
	}

	// A session opened with no fix cannot judge distance. It accepts on the code and the window
	// alone rather than rejecting everyone: refusing a whole hall because the lecturer's phone
	// could not see a satellite would turn a weak signal into an absence record for every student.
	if !s.HasLocation {
		return GeoVerdict{OK: true, Reason: ""}
	}

	// 0,0 is the null island in the Gulf of Guinea — what a phone reports when it has no fix and
	// the client sends the zero value anyway. Treating it as a real coordinate would measure a
	// student as several thousand kilometres away and reject them for a bug in their handset.
	if lat == 0 && lon == 0 {
		return GeoVerdict{Reason: "your phone did not report a location — turn location on and try again"}
	}

	d := DistanceMeters(s.Lat, s.Lon, lat, lon)
	radius := s.RadiusMeters
	if radius <= 0 {
		radius = DefaultRadiusMeters
	}
	if int(math.Round(d)) > radius {
		return GeoVerdict{
			Distance: int(math.Round(d)),
			Reason:   "you are too far from where this lecture was opened",
		}
	}
	return GeoVerdict{OK: true, Distance: int(math.Round(d))}
}

// sessionCodeAlphabet omits the characters people mishear or mistype when a code is read across a
// room: I/1, O/0, and the S/5 and Z/2 pairs. A code exists to be spoken, so its alphabet is chosen
// for the ear rather than for entropy.
const sessionCodeAlphabet = "ABCDEFGHJKLMNPQRTUVWXY346789"

// NewSessionCode returns a short code in U-Panel's shape (four characters, e.g. "G60M").
//
// Drawn from crypto/rand, not math/rand: the code is the thing standing between a passer-by and a
// register, and a predictable sequence would let anyone who saw yesterday's code guess today's.
func NewSessionCode(n int) (string, error) {
	if n <= 0 {
		n = 4
	}
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	out := make([]byte, n)
	for i, v := range b {
		out[i] = sessionCodeAlphabet[int(v)%len(sessionCodeAlphabet)]
	}
	return string(out), nil
}

// NormaliseSessionCode makes a typed code comparable: people type lower case, add spaces, and
// occasionally paste a code with a trailing newline.
func NormaliseSessionCode(s string) string {
	return strings.ToUpper(strings.Join(strings.Fields(strings.TrimSpace(s)), ""))
}
