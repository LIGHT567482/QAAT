package attendance

import (
	"strconv"
	"strings"
	"time"
)

// ParseTimestamp ports check_in._parse_timestamp: it accepts an RFC3339 string,
// a Unix epoch in seconds or milliseconds (int64, float64, or a number as text),
// or an already-typed time. Inputs without a zone are assumed UTC. nil inputs
// return nil.
func ParseTimestamp(v any) *time.Time {
	switch val := v.(type) {
	case nil:
		return nil
	case time.Time:
		if val.IsZero() {
			return nil
		}
		out := val.UTC()
		return &out
	case *time.Time:
		return ParseTimestamp(*val)
	case int64:
		return fromEpoch(val)
	case int:
		return fromEpoch(int64(val))
	case float64:
		return fromEpochFraction(val)
	case string:
		return parseText(val)
	default:
		// Anything exotic (bool, struct, ...) cannot honestly be a timestamp.
		return nil
	}
}

// fromEpoch handles an integer epoch. A 13+ digit value is milliseconds
// (2026 in ms is ~1.78e12); a 10-digit value is seconds. The conversion to
// nanoseconds happens via time.Unix(0, ns) so the two paths meet exactly.
func fromEpoch(secs int64) *time.Time {
	if secs > 1e12 {
		t := time.Unix(0, secs*int64(time.Millisecond)).UTC()
		return &t
	}
	t := time.Unix(secs, 0).UTC()
	return &t
}

// fromEpochFraction handles a float epoch, trying milliseconds first then
// seconds — the same order check_in.py uses.
func fromEpochFraction(f float64) *time.Time {
	// A float with 13+ digits is milliseconds, else seconds.
	if f >= 1e12 {
		t := time.Unix(0, int64(f)*int64(time.Millisecond)).UTC()
		return &t
	}
	if f < 0 {
		return nil
	}
	sec := int64(f)
	ns := int64((f - float64(sec)) * 1e9)
	t := time.Unix(sec, ns).UTC()
	return &t
}

// parseText resolves a string timestamp: an ISO-8601/RFC3339 layout (with or
// without a zone, with or without a T), or a numeric epoch as last resort.
func parseText(s string) *time.Time {
	text := strings.TrimSpace(s)
	if text == "" {
		return nil
	}
	for _, layout := range []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.999999999",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04:05",
		"2006-01-02 15:04",
		"2006-01-02",
	} {
		if t, err := time.Parse(layout, text); err == nil {
			out := t.UTC()
			return &out
		}
	}
	// A bare number — seconds or milliseconds.
	if n, err := strconv.ParseFloat(text, 64); err == nil {
		return fromEpochFraction(n)
	}
	return nil
}