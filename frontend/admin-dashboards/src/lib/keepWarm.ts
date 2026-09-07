// App-heartbeat keepalive — while any dashboard tab/device runs, the gateway's
// free-tier instance stays awake. A single health GET every few minutes from each
// open device is enough to keep Render from idling the whole stack into the
// "server is not answering properly (HTTP 502)" state, independent of GitHub cron
// (`scripts/keepalive.sh` + the workflow are the same idea at the infra level).
//
// This is deliberately fire-and-forget: a background heartbeat failing must never
// surface an error in the UI, and it must never block the first paint.
import { BASE } from './api'

const HEALTH = `${BASE}/api/v1/health`
const INTERVAL_MS = 4 * 60 * 1000

let started = false

function ping() {
  // no-store keeps the browser from answering out of its own HTTP cache — the point
  // is to make a real round trip to the warm endpoints.
  fetch(HEALTH, { cache: 'no-store' }).catch(() => { /* offline / waking — next tick handles it */ })
}

export function startKeepWarm() {
  if (started || typeof window === 'undefined') return
  started = true
  // First ping immediately: paging back to the app must wake the backend right away,
  // not wait for the next 4-minute tick.
  ping()
  window.setInterval(ping, INTERVAL_MS)
  // Re-wake the moment the tab returns to the foreground after a laptop sleep or a
  // long trip to another tab — that's exactly the window during which idle time accrues.
  document.addEventListener('visibilitychange', () => { if (!document.hidden) ping() })
  window.addEventListener('online', ping)
}