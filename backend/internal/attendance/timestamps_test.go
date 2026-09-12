package attendance

import (
	"testing"
	"time"
)

func TestParseTimestamp(t *testing.T) {
	cases := []struct {
		name string
		in   any
		want string // RFC3339 of the expected instant; "" means nil
	}{
		{"nil", nil, ""},
		{"rfc3339 with zone", "2026-09-11T09:30:00+03:00", "2026-09-11T06:30:00Z"},
		{"rfc3339 utc", "2026-09-11T09:30:00Z", "2026-09-11T09:30:00Z"},
		{"space separator", "2026-09-11 09:30:00", "2026-09-11T09:30:00Z"},
		{"space separator with zone", "2026-09-11 09:30:00+03:00", "2026-09-11T06:30:00Z"},
		{"ms int64", int64(1768105800000), "2026-01-11T04:30:00Z"},
		{"s int64", int64(1768105800), "2026-01-11T04:30:00Z"},
		{"mf float", float64(1768105800000), "2026-01-11T04:30:00Z"},
		{"s float", float64(1768105800.5), "2026-01-11T04:30:00.5Z"},
		{"numeric text", "1768105800000", "2026-01-11T04:30:00Z"},
		{"time.Time", time.Date(2026, 9, 11, 9, 0, 0, 0, time.UTC), "2026-09-11T09:00:00Z"},
		{"empty string", "  ", ""},
		{"garbage", "not-a-time", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ParseTimestamp(c.in)
			if c.want == "" {
				if got != nil {
					t.Fatalf("want nil, got %v", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("want %s, got nil", c.want)
			}
			if got.Format(time.RFC3339Nano) != c.want {
				t.Fatalf("want %s, got %s", c.want, got.Format(time.RFC3339Nano))
			}
		})
	}
}

func TestNormaliseCode(t *testing.T) {
	cases := map[string]string{
		"G60M":  "G60M",
		" g60m": "G60M",
		"g 6 0 m\n": "G60M",
		"":      "",
	}
	for in, want := range cases {
		if got := NormaliseCode(in); got != want {
			t.Fatalf("NormaliseCode(%q) = %q, want %q", in, got, want)
		}
	}
}