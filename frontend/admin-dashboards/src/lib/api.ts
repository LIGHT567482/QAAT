// Typed API client — injects Bearer token from session storage automatically.

export const BASE = import.meta.env.VITE_API_URL ?? (typeof location !== 'undefined' ? `${location.protocol}//${location.hostname}:8443` : 'http://localhost:8443')

function getToken(): string {
  try {
    const raw = sessionStorage.getItem('qaat_admin_token')
    if (!raw) return ''
    return (JSON.parse(raw) as { token: string }).token ?? ''
  } catch {
    return ''
  }
}

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms))

// A 502/503/504/429 at the gateway is the free-tier backend WAKING UP, not a verdict
// on the request — Render spins an idle instance up behind its proxy and the wake takes
// longer than the proxy's timeout, so the answer is an HTML holding page (or a 429
// throttle). The login form already knows this and retries through it; this client had
// no such logic, which is why a dashboard clicked after a quiet stretch flashed
// "The server is not answering properly yet (HTTP 502)" at a user whose credentials and
// network were both fine. Retry through the wake with backoff instead.
//
// The body is always reusable across retries: `request` sends a JSON.stringify'd string,
// `upload` sends a FormData. Both rewind naturally.
async function wakeFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const attempts = 5
  for (let i = 0; i < attempts; i++) {
    let res: Response
    try {
      res = await fetch(input, init)
    } catch {
      // No server reached at all — genuine network failure, the one thing this is not a
      // wake-up for.
      if (i === attempts - 1) throw new Error('Could not reach the server. Check your connection.')
      await sleep(1500 * (i + 1))
      continue
    }
    const waking = res.status === 429 || res.status === 502 || res.status === 503 || res.status === 504
    if (waking && i < attempts - 1) {
      const after = Number(res.headers.get('Retry-After')) || 0
      const wait = Math.min(Math.max(after * 1000, 2000 * (i + 1)), 10000)
      await sleep(wait)
      continue
    }
    return res
  }
  throw new Error('The server is still waking up. Wait about a minute and try again.')
}

// Error surfacing that tells 5xx-holding-page apart from a real API error. A gateway
// wake that outlasted every retry deserves the same honest wording login uses, not a
// raw "HTTP 502" that reads like the backend fell over.
function toApiError(res: Response, bodyText: string): Error {
  const looksHTML = bodyText.trimStart().startsWith('<')
  let parsed: { message?: string; error?: string } | null = null
  if (!looksHTML) {
    try { parsed = JSON.parse(bodyText) } catch { /* not JSON */ }
  }
  const msg = parsed?.message?.trim() ? parsed.message : parsed?.error?.trim() ? parsed.error : ''
  return Object.assign(
    new Error(msg || (looksHTML
      ? `The server is not answering properly yet (HTTP ${res.status}). Wait a moment and try again.`
      : `HTTP ${res.status}`)),
    { status: res.status, code: parsed?.error },
  )
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await wakeFetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${getToken()}`,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    throw toApiError(res, await res.text().catch(() => ''))
  }
  // 204 No Content (e.g. DELETE) or any empty body → don't try to parse JSON,
  // which would throw and make a successful call look like a failure.
  if (res.status === 204) return undefined as unknown as T
  const text = await res.text()
  return (text ? JSON.parse(text) : undefined) as T
}

async function upload<T>(path: string, form: FormData): Promise<T> {
  const res = await wakeFetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${getToken()}` }, // no Content-Type → browser sets multipart boundary
    body: form,
  })
  if (!res.ok) {
    throw toApiError(res, await res.text().catch(() => ''))
  }
  return res.json() as Promise<T>
}

// Authenticated file download (e.g. XLSX export) — fetches a blob with the bearer
// token and triggers a browser download. A plain <a href> can't send the header.
async function download(path: string, filename: string): Promise<void> {
  const res = await wakeFetch(`${BASE}${path}`, { headers: { Authorization: `Bearer ${getToken()}` } })
  if (!res.ok) throw toApiError(res, await res.text().catch(() => ''))
  const blob = await res.blob()
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a'); a.href = url; a.download = filename; a.click(); URL.revokeObjectURL(url)
}

export const api = {
  get:    <T>(path: string)                => request<T>('GET',    path),
  put:    <T>(path: string, body: unknown) => request<T>('PUT',    path, body),
  post:   <T>(path: string, body?: unknown)=> request<T>('POST',   path, body),
  patch:  <T>(path: string, body?: unknown)=> request<T>('PATCH',  path, body),
  delete: <T>(path: string)                => request<T>('DELETE', path),
  upload: <T>(path: string, form: FormData)=> upload<T>(path, form),
  download,
}

// ─── Response types ───────────────────────────────────────────────────────────

export interface ThresholdConfig {
  attendance_threshold:    number
  checkin_window_minutes:  number
  auto_kill_minutes:       number
}

export interface EligibilityUnit {
  unit_id:              string
  unit_name:            string
  sessions_held:        number
  sessions_attended:    number
  attendance_percentage: number
  threshold:            number
  status:               'ELIGIBLE' | 'EXAM_INELIGIBLE'
  deficit_sessions?:    number
}

export interface EligibilityRecord {
  student_id:    string
  academic_year: string
  semester:      number
  units:         EligibilityUnit[]
}

export interface VCOverview {
  total_sessions_scheduled: number
  total_sessions_actual:    number
  total_students_today:     number
  ghost_lecture_count:      number
  avg_attendance_pct:       number
  ier:                      string
  eligibility_summary: {
    eligible:   number
    ineligible: number
    pending:    number
  }
  ghost_sessions: GhostSession[]
  filters: { date_from: string; date_to: string; course_id: string; unit_id: string; department: string }
}

export interface GhostSession {
  session_id:    string
  unit_id:       string
  unit_name:     string
  session_date:  string
  student_count: number
}

export interface WorkloadRecord {
  coordinator_id:          string
  coordinator_name:        string
  scheduled_sessions:      number
  actual_sessions:         number
  total_contact_hours_actual: number
  distinct_units:          number
  attendance_rate_pct:     number
}

export interface CourseHealthUnit {
  unit_id:               string
  unit_name:             string
  course_id:             string
  course_name:           string
  department:            string
  enrolled_count:        number
  avg_attendance_pct:    number
  below_threshold_count: number
  threshold:             number
  risk_level:            'HEALTHY' | 'AT_RISK' | 'CRITICAL'
}

export interface TrendPoint {
  week_start:             string
  sessions_held:          number
  unique_students:        number
  total_checkins:         number
  avg_students_per_session: number
}

export interface PunctualityRecord {
  coordinator_id:   string
  coordinator_name: string
  total_sessions:   number
  gate_opened_count: number
  no_gate_open_count: number
  avg_wait_minutes: number
  late_open_count:  number
}

export interface IneligibleRecord {
  student_id:         string
  student_name:       string
  email:              string
  course_id:          string
  course_name:        string
  unit_id:            string
  unit_name:          string
  sessions_held:      number
  sessions_attended:  number
  attendance_percentage: number
  threshold:          number
  deficit_sessions:   number
}

// Every student's per-unit eligibility (eligible + ineligible), with the
// dimensions the DQA dashboard filters on.
export interface AllEligibilityRecord extends IneligibleRecord {
  status:          'ELIGIBLE' | 'INELIGIBLE'
  current_year:    number
  semester:        number
  intake_session:  string
  academic_year:   string
}

export interface CoordinatorHealth {
  coordinator_id:       string
  coordinator_name:     string
  total_sessions:       number
  synced_sessions:      number
  failed_sessions:      number
  pending_sessions:     number
  sync_success_rate:    number
  manual_overrides:     number
  total_checkins:       number
  manual_override_ratio: number
}
