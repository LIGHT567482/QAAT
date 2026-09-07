#!/usr/bin/env bash
# Keep the Render free-tier web instances warm — ALL of them, because any one of
# them asleep behind its proxy is a 502 the moment a real request needs it.
#
# WHY. Every service is on Render's free plan, and a free web instance sleeps after ~15
# minutes of idle. When a real request then arrives, Render's gateway (and the proxy hops
# the gateway itself makes to its siblings) cold-starts in addition to waiting, frequently
# exceeding the platform's ~30s proxy timeout and answering HTTP 502. The symptom is
# intermittent — it only happens after a quiet stretch — which makes it look like an outage
# rather than the free tier working as designed.
#
# ALL FIVE INSTANCES MUST STAY AWAKE, not just the login path:
#   - kiu-qaat-gateway — every authenticated request, front door
#   - kiu-qaat-auth    — every login / token mint (router atoms, Redis blacklist)
#   - kiu-qaat-session — warden session validation during live sessions
#   - kiu-qaat-sync    — the coordinator's sealed uploads land here
#   - kiu-qaat-notify  — the no-show / office-round email + WhatsApp fan-out
# Pinging only the first two kept LOGIN warm but left every other door asleep; a
# patrol sync or a QA notification after a quiet hour then 502'd exactly like login used to.
#
# RETRY-UNTIL-WARM. The shallow /health endpoints answer without touching the database, so
# waking an instance is free — but a wake takes seconds, longer than the platform's proxy
# timeout of ~30s. So a 502/503 on a ping is re-tried every 15s until it answers 200: this
# script does not declare an instance warm, it CONFIRMS it. Whoever got woken stays woken
# for the next scheduled ping, and the cold-start window a real user would have hit is closed.
#
# USAGE (any one):
#   scripts/keepalive.sh                 # ping once, confirm warm, exit 0/1
#   scripts/keepalive.sh --loop 300      # ping every 300s forever (always-on machine)
#   scripts/keepalive.sh --list          # print the endpoints
#
# EXIT CODE. Single-shot mode ends non-zero if any instance could not be confirmed warm
# (or answers something unexpected), so the scheduled GitHub job shows red and Render-free
# Watson (the Actions failure email) pages you — a genuinely dead service alerts instead
# of silently degrading. --loop mode never stops on a failure; it warns and keeps warming.
#
# Deployed as a scheduled GitHub Actions job every 5 minutes; for defence in depth, run
# the same script in a loop on any always-on machine (the Contabo VPS, an office box):
#   scripts/keepalive.sh --loop 300 &
# GitHub's own scheduling can jitter a run by up to ~15 minutes — the retry-until-warm
# logic absorbs that, because whatever the run late-finds asleep, it wakes and confirms.
set -u

ENDPOINTS=(
  # Render free web instances, front-of-stack first. The gateway's route is /api/v1/health;
  # the four sibling services all answer plain /health. All five are deliberately shallow.
  "https://kiu-qaat-gateway.onrender.com/api/v1/health"
  "https://kiu-qaat-auth.onrender.com/health"
  "https://kiu-qaat-session.onrender.com/health"
  "https://kiu-qaat-sync.onrender.com/health"
  "https://kiu-qaat-notify.onrender.com/health"
)

# Retry cadence while waking an instance (seconds between attempts, max attempts).
retry_every=15
max_attempts=8 # 8 × 15s ≈ up to ~2min behind the first attempt — enough for a cold boot

interval=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --list) printf '%s\n' "${ENDPOINTS[@]}"; exit 0 ;;
    --loop) interval="${2:?usage: --loop <seconds>}"; shift 2 ;;
    --health) : ;; # ping once (default)
    *) echo "usage: keepalive.sh [--list | --loop <seconds>]" >&2; exit 2 ;;
  esac
fi

warn() { echo "keepalive: WARN $*" >&2; }

fail=0
while :; do
  started=$(date +%s)
  for url in "${ENDPOINTS[@]}"; do
    ok=0
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
      code=$(curl -sS -o /dev/null -w '%{http_code}' -m 60 "$url" 2>/dev/null)
      case "$code" in
        "")   warn "curl could not reach $url — network/DNS?" ;;
        200)  ok=1; break ;;
        502|503) # Render route-to-backend mid-cold-start. Expected on a wake, not a fault.
          if (( attempt < max_attempts )); then
            warn "cold-start $code waking $url (attempt $attempt/$max_attempts) — real users would 502 here until it's warm"
            sleep "$retry_every"
            continue
          fi
          warn "still $code after $max_attempts attempts — instance not confirmed warm: $url" ;;
        *) # 404 from a path change, 401 from a broken route, anything unexpected: genuinely wrong.
          warn "unexpected HTTP $code from $url (a 404 means the health path moved)" ;;
      esac
      break
    done
    (( ok )) || fail=1
  done
  if [[ "$interval" -le 0 ]]; then
    break
  fi
  elapsed=$(( $(date +%s) - started ))
  sleep_=$(( interval - elapsed ))
  sleep_=$(( sleep_ > 0 ? sleep_ : 0 ))
  if (( fail )); then
    fail=0 # loop mode: report once per pass, keep warming
  fi
  sleep "$sleep_"
done
exit "$fail"