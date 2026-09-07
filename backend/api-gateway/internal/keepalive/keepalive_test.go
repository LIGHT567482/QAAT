package keepalive

import (
	"testing"
	"time"
)

func TestTargetsDedupe(t *testing.T) {
	got := targets(Targets{
		Self:     "https://gateway/api/v1/health",
		Siblings: []string{"https://auth/health", " ", "https://gateway/api/v1/health", "https://sync/health"},
	})
	want := []string{"https://gateway/api/v1/health", "https://auth/health", "https://sync/health"}
	if len(got) != len(want) {
		t.Fatalf("len = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("targets[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestTargetsEmpty(t *testing.T) {
	if n := len(targets(Targets{})); n != 0 {
		t.Fatalf("empty config must produce no targets, got %d (%v)", n, targets(Targets{}))
	}
}

func TestJitteredStaysAboveInterval(t *testing.T) {
	interval := 4 * time.Minute
	for range 200 {
		if j := jittered(interval, 30*time.Second); j < interval {
			t.Fatalf("jittered %v dropped below interval %v", j, interval)
		}
	}
}
