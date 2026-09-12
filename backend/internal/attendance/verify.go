// Package attendance decides whether a student's check-in attempt is accepted.
//
// It is a faithful Go port of U-Panel's attendance engine
// (backend/documents/services/check_in.py — maybe_process_check_in), which QAAT
// adopts wholesale under decision E of docs/U-PANEL-MIGRATION.md. The rules are
// deliberately identical so that the two systems agree on what "PRESENT" means
// and a QA officer reading either system sees the same concept:
//
//   - an attempt resolves to a session, either because the hub already claimed
//     its session id or because a spoken code was matched to an open session;
//   - a claim with no resolvable session stays PENDING for the sweep job to
//     retry, exactly U-Panel's "awaitingSession" path;
//   - the capture must fall inside the session's time window (with the same
//     clock-skew tolerances: 2 minutes' grace at the start, server receipt time
//     trusted when the device clock is more than 5 minutes adrift);
//   - one device cannot mark two different students present in one session;
//   - the capture must be inside the session's circle (radius + 25 m buffer +
//     GPS uncertainty from both ends), unless the session allows remote learning
//     or is still waiting for its own location;
//   - a record that already ties the student to the session is idempotent: the
//     attempt is marked accepted but no second record is written.
//
// Everything here is free of I/O so the rules can be tested exactly. The caller
// supplies the current state through the Lookup and Facts callbacks; writing the
// verdict row is the caller's job.
package attendance

import (
	"math"
	"strings"
	"time"
)

// Verdict is the final or interim state of one check-in attempt, mirroring the
// status field on U-Panel's attendance/check-in-attempts documents.
type Verdict string

const (
	// VerdictAccepted means the attempt passes and a NEW record must be written.
	VerdictAccepted Verdict = "accepted"
	// VerdictDuplicate means the attempt passes but the record already exists;
	// the attempt is still marked accepted, just no second record is written.
	VerdictDuplicate Verdict = "duplicate"
	// VerdictRejected means the attempt fails; Reason says why.
	VerdictRejected Verdict = "rejected"
	// VerdictPending means the session could not be resolved yet (the lecturer
	// has not opened it). The sweep job retries later — never burn the attempt.
	VerdictPending Verdict = "pending"
)

// Geofence constants, translated from check_in.py.
const (
	// GeofenceBufferMeters is U-Panel's GEOFENCE_BUFFER_METERS: a student 24 m
	// outside the circle still counts as inside, because GPS is not that precise.
	GeofenceBufferMeters = 25
	// MaxGPSUncertaintyBufferMeters is U-Panel's MAX_GPS_UNCERTAINTY_BUFFER_METERS.
	MaxGPSUncertaintyBufferMeters = 75
	// DefaultRadiusMeters matches sessions.radius_meters' column default (1500)
	// and the radius observed on U-Panel sessions. check_in.py's fallback was 50,
	// but a fallback only fires for a session whose centre it cannot parse, and
	// QAAT always stamps a real radius — 1500 is the honest standby.
	DefaultRadiusMeters = 1500
	// EarthRadiusMeters is the mean radius used by the haversine formula.
	EarthRadiusMeters = 6371000.0

	// ClockSkewGraceWindow allows captures up to 2 minutes early (early arrivals,
	// a lecturer starting slightly late).
	ClockSkewGraceWindow = 2 * time.Minute
	// ServerTrustThreshold is the skew beyond which the device clock is declared
	// adrift and the server receipt time becomes the effective capture time.
	ServerTrustThreshold = 5 * time.Minute
)

// Attempt is what the client sent. A hub-session claim carries SessionID; a
// typed code carries SessionCode; both flows may also carry a device + GPS fix.
type Attempt struct {
	StudentID         string
	DeviceID          string
	Latitude          float64
	Longitude         float64
	GPSAccuracyMeters float64
	CapturedAt        *time.Time // device-reported capture time
	ReceivedAt        *time.Time // server receipt time
	SessionID         string     // claimed session id (hub already knows the session)
	SessionCode       string     // raw spoken code, when the session is resolved by code
	AwaitingSession   bool       // U-Panel's awaitingSession flag: keep claiming, not rejected
}

// Session is the resolved session the attempt is judged against.
type Session struct {
	ID                       string
	ListID                   string
	Code                     string // the spoken code, for cache building (not judged)
	Status                   string // "ACTIVE", "PENDING_LECTURER", ...
	Start                    *time.Time
	End                      *time.Time
	Latitude                 float64
	Longitude                float64
	RadiusMeters             int
	GPSAccuracyMeters        float64
	RemoteLearning           bool // U-Panel session_data.remoteLearning bypass
	LocationMetadataPending  bool // U-Panel session_data.locationMetadataPending bypass
}

// Lookup is how the engine resolves a session. Exactly one of the two branches
// is taken per attempt: ByID for a hub claim, ByCode for a spoken code.
type Lookup struct {
	ByID   func(id string) *Session
	ByCode func(code string) *Session
}

// Facts is the current database-backed state the caller has already queried.
type Facts struct {
	Now time.Time // server time; zero means time.Now().UTC()
	// RecordExists reports whether a record already ties this student to this
	// session (the record key is sessionId_studentId). Nil means "no".
	RecordExists func(sessionID, studentID string) bool
	// DeviceUsedByOther reports whether the device already marked a DIFFERENT
	// student present in this session. Nil means "no".
	DeviceUsedByOther func(sessionID, deviceID, studentID string) bool
}

// Decision is the verdict plus everything the caller needs to act on it.
type Decision struct {
	Verdict        Verdict
	Reason         string   // rejection reason; empty when not rejected
	SessionID      string   // resolved session ("" while Pending with no session)
	ListID         string   // resolved list
	DistanceMeters int      // distance from the session centre, rounded
}

// Evaluate runs one attempt through U-Panel's pipeline in its exact order. A
// rejected student asking "but I was there" is answered by Reason + Distance.
func Evaluate(a Attempt, lookup Lookup, facts Facts) Decision {
	now := facts.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}

	// ── session resolution ──────────────────────────────────────────────────
	var session *Session
	switch {
	case a.SessionID != "" && !a.AwaitingSession:
		// The hub already resolved the session: trust its claim, then prove the
		// session still exists under us.
		if lookup.ByID != nil {
			session = lookup.ByID(a.SessionID)
		}
		if session == nil {
			return Decision{Verdict: VerdictRejected, Reason: "session does not match"}
		}

	case a.SessionCode != "":
		// Spoken code: resolve against open sessions, case-insensitively.
		if lookup.ByCode != nil {
			session = lookup.ByCode(NormaliseCode(a.SessionCode))
		}
		if session == nil {
			if a.AwaitingSession {
				return Decision{Verdict: VerdictPending, SessionID: a.SessionID}
			}
			return Decision{Verdict: VerdictRejected, Reason: "session code not found"}
		}

	default:
		// Neither a claimed id nor a code. A claim that was waiting for one (the
		// sweep may attach it) stays pending; otherwise there is nothing to link.
		if a.AwaitingSession {
			return Decision{Verdict: VerdictPending, SessionID: a.SessionID}
		}
		return Decision{Verdict: VerdictRejected, Reason: "session code not found"}
	}

	// ── which student ───────────────────────────────────────────────────────
	studentID := strings.TrimSpace(a.StudentID)
	if studentID == "" {
		return Decision{Verdict: VerdictRejected, Reason: "missing student id",
			SessionID: session.ID, ListID: session.ListID}
	}

	// ── time window ─────────────────────────────────────────────────────────
	if !withinSessionTime(session, a, now) {
		return Decision{Verdict: VerdictRejected, Reason: "outside session time",
			SessionID: session.ID, ListID: session.ListID}
	}

	// ── one device, one person ──────────────────────────────────────────────
	if deviceUsedByOther(session, a, facts) {
		return Decision{Verdict: VerdictRejected, Reason: "device already used for another student",
			SessionID: session.ID, ListID: session.ListID}
	}

	// ── geofence ────────────────────────────────────────────────────────────
	inCircle, distance := withinGeofence(session, a)
	if !inCircle {
		return Decision{Verdict: VerdictRejected, Reason: "outside class location",
			SessionID: session.ID, ListID: session.ListID, DistanceMeters: distance}
	}

	// ── record ──────────────────────────────────────────────────────────────
	if facts.RecordExists != nil && facts.RecordExists(session.ID, studentID) {
		return Decision{Verdict: VerdictDuplicate, SessionID: session.ID,
			ListID: session.ListID, DistanceMeters: distance}
	}
	return Decision{Verdict: VerdictAccepted, SessionID: session.ID,
		ListID: session.ListID, DistanceMeters: distance}
}

// withinSessionTime ports check_in._within_session_time, including both
// clock-skew tolerances.
func withinSessionTime(s *Session, a Attempt, now time.Time) bool {
	effective := effectiveCaptureTime(a, now)

	if s.Start != nil && effective.Before(*s.Start) {
		if s.Start.Sub(effective) > ClockSkewGraceWindow {
			return false
		}
	}
	if s.End != nil && effective.After(*s.End) && !sessionActive(s.Status) {
		return false
	}
	return true
}

// effectiveCaptureTime applies U-Panel's rule: the device clock is trusted up to
// 5 minutes of drift; beyond that, the server receipt time cannot be spoofed by
// a drifted clock and wins.
func effectiveCaptureTime(a Attempt, now time.Time) time.Time {
	if a.CapturedAt == nil {
		if a.ReceivedAt != nil {
			return *a.ReceivedAt
		}
		return now
	}
	if a.ReceivedAt != nil {
		skew := a.ReceivedAt.Sub(*a.CapturedAt)
		if skew < 0 {
			skew = -skew
		}
		if skew > ServerTrustThreshold {
			return *a.ReceivedAt
		}
	}
	return *a.CapturedAt
}

func sessionActive(status string) bool {
	return strings.ToLower(strings.TrimSpace(status)) == "active"
}

// withinGeofence ports check_in._within_geofence. It returns whether the capture
// is inside the circle and the distance from the centre for the verdict row.
func withinGeofence(s *Session, a Attempt) (bool, int) {
	if s.RemoteLearning || s.LocationMetadataPending {
		return true, 0
	}
	// A session opened with no fix cannot judge distance: it accepts on the code
	// and window alone rather than reject an entire hall because the lecturer's
	// device could not see a satellite.
	if s.Latitude == 0 && s.Longitude == 0 {
		return true, 0
	}
	// The null island: what a device reports when it has no fix and sends 0,0
	// anyway. Treating it as a coordinate measures the student thousands of
	// kilometres away — reject politely, it is a handset bug, not absence.
	if math.Abs(a.Latitude) < 0.001 && math.Abs(a.Longitude) < 0.001 {
		return false, 0
	}
	radius := s.RadiusMeters
	if radius <= 0 {
		radius = DefaultRadiusMeters
	}
	distance := HaversineMeters(s.Latitude, s.Longitude, a.Latitude, a.Longitude)
	uncertainty := gpsUncertaintyBuffer(a.GPSAccuracyMeters) +
		gpsUncertaintyBuffer(s.GPSAccuracyMeters)
	ok := distance <= float64(radius)+GeofenceBufferMeters+uncertainty
	return ok, int(math.Round(distance))
}

// gpsUncertaintyBuffer ports check_in._gps_uncertainty_buffer.
func gpsUncertaintyBuffer(accuracyMeters float64) float64 {
	if accuracyMeters <= 0 {
		return 0
	}
	if b := accuracyMeters * 0.5; b > MaxGPSUncertaintyBufferMeters {
		return MaxGPSUncertaintyBufferMeters
	} else {
		return b
	}
}

// HaversineMeters is the great-circle distance between two points on a sphere
// of EarthRadiusMeters. (Same formula as the api-gateway checkin package; the
// shared engine owns a copy so the sync x api-gateway modules do not cross.)
func HaversineMeters(lat1, lon1, lat2, lon2 float64) float64 {
	toRad := func(d float64) float64 { return d * math.Pi / 180 }
	dLat := toRad(lat2 - lat1)
	dLon := toRad(lon2 - lon1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(toRad(lat1))*math.Cos(toRad(lat2))*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * EarthRadiusMeters * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// UsableDeviceID ports check_in._usable_device_id: emulator/unknown built-in
// values are shared across unrelated handsets and must not be treated as unique.
func UsableDeviceID(raw string) string {
	id := strings.ToLower(strings.TrimSpace(raw))
	if id == "" {
		return ""
	}
	if _, ok := genericDeviceIDs[id]; ok {
		return ""
	}
	return id
}

var genericDeviceIDs = map[string]struct{}{
	"unknown": {}, "0": {}, "9774d56d682e549c": {}, "0000000000000000": {},
	"android": {}, "null": {}, "undefined": {},
}

func deviceUsedByOther(s *Session, a Attempt, facts Facts) bool {
	deviceID := UsableDeviceID(a.DeviceID)
	if deviceID == "" || s.ID == "" || facts.DeviceUsedByOther == nil {
		return false
	}
	return facts.DeviceUsedByOther(s.ID, deviceID, strings.TrimSpace(a.StudentID))
}

// NormaliseCode makes a typed code comparable: people type lower case, add
// spaces, and occasionally paste a trailing newline. Its result is also how the
// session code column is matched in SQL.
func NormaliseCode(s string) string {
	return strings.ToUpper(strings.Join(strings.Fields(strings.TrimSpace(s)), ""))
}