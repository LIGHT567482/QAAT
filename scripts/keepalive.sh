#!/usr/bin/env bash
# Keep the Render free-tier web instances warm.
#
# WHY. Every service is on Render's free plan, and a free web instance sleeps after ~15 minutes
# of idle. When a real request then arrives, Render's gateway (and the two proxy hops the gateway
# itself makes to its siblings) has to cold-start on top of waiting, frequently exceeding the
# platform's ~30s proxy timeout and answering HTTP 502. The symptom is intermittent — it only
# happens after a quiet stretch — which makes it look like an outage rather than the free tier
# working as designed.
#
# The login path that actually 502s is gateway -> auth-service (which then touches Postgres +
# Redis). So this warms BOTH endpoints directly, because pinging the gateway alone still leaves
# the auth instance behind it asleep. The two /health endpoints are deliberately shallow — they
# answer without touching the database or performing real work, so a warm is free.
#
# USAGE (any one):
#   scripts/keepalive.sh                 # ping once, quiet
#   scripts/keepalive.sh --loop 300      # ping every 300s forever (cron/CI replacement)
#   scripts/keepalive.sh --list          # print the endpoints
#
# It is installed as a scheduled GitHub Actions job that pings every 5 (plan) minutes; running it
# locally in a loop is the equivalent for machines that stay on. Add more endpoints as more
# services need to wake on the same request path (session/sync/notify sleep too but are not on
# login, so login is fixed by gateway + auth alone).
set -u

ENDPOINTS=(
  # The two instances that cold-start on the login path, in the order the request itself hits
  # them (gateway front, auth behind).
  "https://kiu-qaat-gateway.onrender.com/api/v1/health"
  "https://kiu-qaat-auth.onrender.com/health"
)

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

while :; do
  started=$(date +%s)
  for url in "${ENDPOINTS[@]}"; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -m 60 "$url" 2>/dev/null)
    # 200 is expected; 502/503 is Render route-to-backend mid-cold-start, which the request
    # that triggered it has already spent waking — it answers on a later attempt. Anything else
    # (404 from a path change, DNS failure) is genuinely wrong and worth a line.
    if [[ "$code" == "200" ]]; then
      continue
    fi
    case "$code" in
      502|503) warn "cold-start 502/503 waking $url (expected on a wake, not a fault)" ;;
      *)       warn "unexpected HTTP $code from $url" ;;
    esac
  done
  if [[ "$interval" -le 0 ]]; then
    break
  fi
  elapsed=$(( $(date +%s) - started ))
  sleep_=$(( interval - elapsed ))
  sleep_=$(( sleep_ > 0 ? sleep_ : 0 ))
  sleep "$sleep_"
done