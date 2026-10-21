// Package attendance is the MERGE SLOT for the attendance engine.
//
// The adjudication gates, join-code lifecycle, geofence/device checks, roll
// math and the sweeps are specified in docs/qaat-spec/06-attendance-module.md
// and are implemented SEPARATELY, then merged into this package. Until that
// merge lands, every exported entry point returns ErrNotMerged and the HTTP
// layer surfaces it as 501 {"error":"attendance logic pending merge",...}.
//
// TODO(attendance-merge): fill the functions below per spec doc 06. Keep the
// exported signatures and the ErrNotMerged sentinel so route wiring and tests
// do not need to change when the merge lands.
package attendance

import "errors"

// ErrNotMerged is returned by every engine entry point until the attendance
// merge lands. The API layer maps it to HTTP 501.
var ErrNotMerged = errors.New("attendance logic pending merge")

// Spec pointer attached to every 501 response body.
const SpecRef = "docs/qaat-spec/06-attendance-module.md"

// Attempt is a raw student check-in submission awaiting adjudication
// (spec doc 06 §4). The merge implements gates 0-7 over this input.
type Attempt struct {
	ID                string   `json:"id"`
	SessionID         string   `json:"sessionId,omitempty"`
	SessionCodeRaw    string   `json:"sessionCodeRaw,omitempty"`
	StudentID         string   `json:"studentId"`
	ListID            string   `json:"listId,omitempty"`
	Course            string   `json:"course,omitempty"`
	DeviceID          string   `json:"deviceId,omitempty"`
	Latitude          *float64 `json:"latitude,omitempty"`
	Longitude         *float64 `json:"longitude,omitempty"`
	GPSAccuracyMeters *float64 `json:"gpsAccuracyMeters,omitempty"`
	CapturedAt        string   `json:"capturedAt,omitempty"`
	ClientSubmittedAt string   `json:"clientSubmittedAt,omitempty"`
}

// Result is the server-adjudicated outcome written back to the attempt
// (spec doc 06 §4.4). Rejections are stored outcomes, not HTTP errors.
type Result struct {
	ID              string `json:"id"`
	Status          string `json:"status"` // pending | accepted | rejected
	SessionID       string `json:"sessionId,omitempty"`
	ListID          string `json:"listId,omitempty"`
	RejectionReason string `json:"rejectionReason,omitempty"`
	AwaitingSession bool   `json:"awaitingSession"`
}

// Verify runs the synchronous check-in adjudication gates 0-7 over a single
// attempt (spec doc 06 §4). TODO(attendance-merge): implement per spec.
func Verify(a Attempt) (Result, error) {
	return Result{}, ErrNotMerged
}

// SweepAwaitingSessionClaims links pending attempts that arrived before the
// lecturer started the session. Cadence 30s, up to 50 oldest, 7-day window
// (spec doc 04 §7, doc 06 §5). TODO(attendance-merge): implement per spec.
func SweepAwaitingSessionClaims() (int, error) {
	return 0, ErrNotMerged
}

// FinalizeExpiredSessions closes sessions past end_time still marked active
// (spec doc 04 §7, doc 15 §3). Cadence 120s. TODO(attendance-merge): implement.
func FinalizeExpiredSessions() (int, error) {
	return 0, ErrNotMerged
}

// MarkGraceExpiredAbsents converts check-ins unverified past the 7-day grace
// window into present=false records (spec doc 11 §3). TODO(attendance-merge).
func MarkGraceExpiredAbsents() (int, error) {
	return 0, ErrNotMerged
}
