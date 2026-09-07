// Package keepalive keeps the whole Render stack warm from inside the gateway.
//
// Render's free web instances sleep after ~15 minutes of inbound-idle, and a request
// that lands on a sleeping instance cold-starts behind Render's ~30s proxy timeout and
// answers HTTP 502 — which is exactly the "The server is not answering properly yet
// (HTTP 502)" a dashboard shows after a quiet stretch. Logins eventually learned to
// retry through the wake-up, but every OTHER request (a dashboard opening, a report
// download) hit the 502 with no retry at all.
//
// The previous defence was an external scheduled pinger (GitHub Actions cron). It is
// unreliable in exactly the ways that hurt here: GitHub may delay a scheduled run well
// past the 15-minute idle window, and GitHub disables scheduled workflows in a repo that
// goes quiet. A gap between pings lets the stack sleep, and the first real user of the
// day pays for it.
//
// THIS LOOP has no external dependency. While the gateway process is running it fires a
// health ping at its OWN public URL and at every sibling service's public URL every few
// minutes. Each ping enters through Render's edge as inbound traffic to that service,
// resetting its inactivity clock — so as long as the gateway is up, none of the five
// instances ever becomes idle enough to sleep. There is no cold-start window left for a
// user to hit, and nothing outside the repo can stop it.
//
// The cost is that the free instances stop sleeping and run full-time. They were already
// effectively full-time under the scheduled pinger; this makes it even, gap-free and
// unconditionally self-healing (a redeploy warms everything again on the first tick).
package keepalive

import (
	"context"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"strings"
	"time"
)

// Targets configures the warm loop.
type Targets struct {
	Self     string        // the gateway's own public health URL (empty → skip self)
	Siblings []string      // each sibling service's public health URL
	Interval time.Duration // between passes; default 4m
	Jitter   time.Duration // random lead-in each pass; default 30s
	Disabled bool          // set in environments that don't need waking (local dev)
	HTTP     *http.Client
}

// Start launches the warm loop. It does one pass immediately (a freshly deployed
// instance warms itself and its siblings on boot), then repeats on Interval until ctx is
// cancelled. Failures are best-effort and logged — a sibling that is genuinely down stays
// down, but the loop keeps giving it a lift every tick, so a later tick heals it.
func Start(ctx context.Context, log *slog.Logger, t Targets) {
	if t.Disabled {
		log.Info("keepalive: warm loop disabled")
		return
	}
	targets := targets(t)
	if len(targets) == 0 {
		log.Info("keepalive: warm loop has no targets (set SELF/SIBLING health URLs)")
		return
	}
	if t.HTTP == nil {
		t.HTTP = &http.Client{Timeout: 15 * time.Second}
	}
	if t.Interval <= 0 {
		t.Interval = 4 * time.Minute
	}

	log.Info("keepalive: warm loop started",
		"targets", len(targets), "every", t.Interval.String(), "disabled", false)

	go func() {
		// One immediate pass: a fresh deploy boots warm instead of waiting out the
		// first interval.
		pass(ctx, log, t.HTTP, targets)

		for {
			select {
			case <-ctx.Done():
				log.Info("keepalive: warm loop stopped")
				return
			case <-time.After(jittered(t.Interval, t.Jitter)):
				pass(ctx, log, t.HTTP, targets)
			}
		}
	}()
}

// jittered returns interval plus a fraction of jitter, so consecutive wakes never line
// up at the same instant across services.
func jittered(interval, jitter time.Duration) time.Duration {
	if jitter <= 0 {
		return interval
	}
	j := time.Duration(rand.Int64N(int64(jitter)))
	if j > interval {
		j = interval
	}
	return interval + j
}

func targets(t Targets) []string {
	var out []string
	if s := strings.TrimSpace(t.Self); s != "" {
		out = append(out, s)
	}
	for _, s := range t.Siblings {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		dup := false
		for _, e := range out {
			if e == s {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, s)
		}
	}
	return out
}

func pass(ctx context.Context, log *slog.Logger, c *http.Client, targets []string) {
	for _, u := range targets {
		url := u
		go func() {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
			if err != nil {
				log.Warn("keepalive: bad target", "url", url, "error", err)
				return
			}
			resp, err := c.Do(req)
			if err != nil {
				log.Debug("keepalive: unreachable (cold start in progress?)", "url", url, "error", err)
				return
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				log.Warn("keepalive: target answered non-200", "url", url, "status", resp.StatusCode)
			}
		}()
	}
}
