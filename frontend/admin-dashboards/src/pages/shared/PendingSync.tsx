import { useState } from 'react'
import { api } from '../../lib/api'
import { usePoll } from '../../lib/useApi'

/**
 * THE CHECK-INS THAT HAVE NOT LANDED IN THE REGISTER YET.
 *
 * Two kinds of attempt never reach the register immediately:
 *
 *   Waiting for its session — a student typed a code before the lecturer opened the
 *   register. Instead of an outright "session code not found" refusal the phone's claim
 *   is parked (awaiting_session = true) and the sweep job retries it every minute; when
 *   the session opens in time the claim resolves into an ordinary attempt.
 *
 *   Offline queue — a check-in taken with no signal and drained from the phone later.
 *
 * This is that queue, live. An unresolved claim is NOT evidence of presence (that arrives
 * when the sweep resolves it and it shows up in Check-in Attempts), but a queue that is
 * building up says the room is typing codes for a register nobody has opened yet.
 */
interface Claim {
  attempt_id: string
  session_id: string
  student_id: string
  session_code: string
  outcome: 'PRESENT' | 'DUPLICATE' | 'REJECTED' | string
  reason: string
  distance_meters: number | null
  device_id: string
  captured_offline: boolean
  awaiting_session: boolean
  list_id: string
  attempted_at: string
  received_at: string
  resolved_at: string | null
}
interface Resp {
  attempts: Claim[]; total: number; pending: number; offline: number; days: number
}

const POLL_MS = 45_000 // the sweep resolves claims every minute — track it live

export default function PendingSync() {
  const [days, setDays] = useState(7)
  const [status, setStatus] = useState<'all' | 'pending' | 'offline'>('all')
  const [student, setStudent] = useState('')

  const { status: st, data, refetch } = usePoll<Resp>(
    () => api.get(`/api/v1/attendance/pending?days=${days}&status=${status}`
      + (student.trim() ? `&student_id=${encodeURIComponent(student.trim())}` : '')),
    POLL_MS,
  )
  const rows = st === 'ok' ? (data?.attempts ?? []) : []

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6, flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Pending &amp; Offline Sync</h2>
          <p style={{ color: 'var(--muted)', margin: '4px 0 0', fontSize: 13 }}>
            Check-ins still waiting on a session to open, and attempts drained from phone
            queues. Resolved claims move on to Check-in Attempts.
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <input placeholder="Registration number" value={student} onChange={e => setStudent(e.target.value)} style={inp} />
          <select value={status} onChange={e => setStatus(e.target.value as typeof status)} style={inp}>
            <option value="all">All</option>
            <option value="pending">Waiting for session</option>
            <option value="offline">Offline queue</option>
          </select>
          <select value={days} onChange={e => setDays(Number(e.target.value))} style={inp}>
            <option value={1}>Today</option>
            <option value={7}>Last 7 days</option>
            <option value={30}>Last 30 days</option>
          </select>
          <button onClick={refetch} style={btn}>Refresh</button>
        </div>
      </div>

      {st === 'loading' && <p style={{ color: 'var(--muted)' }}>Loading…</p>}
      {st === 'error' && <p style={{ color: '#b91c1c' }}>Failed to load the pending queue.</p>}

      {data && (
        <div style={{ display: 'flex', gap: 12, margin: '16px 0', flexWrap: 'wrap' }}>
          <Kpi label="In queue" value={data.total} tone="#475569" />
          {/* Unresolved claims are the actionable number: the register is open, students are typing, no one lands. */}
          <Kpi label="Waiting on a session" value={data.pending} tone={data.pending > 0 ? '#b45309' : '#16a34a'} />
          <Kpi label="From offline queues" value={data.offline} tone="#2563eb" />
        </div>
      )}

      {st === 'ok' && rows.length === 0 && (
        <p style={{ color: 'var(--muted)', textAlign: 'center', marginTop: 40 }}>
          No pending or offline check-ins in this window.
        </p>
      )}

      {rows.length > 0 && (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13, minWidth: 720 }}>
            <thead>
              <tr style={{ background: 'var(--surface,#f8fafc)', textAlign: 'left' }}>
                {['Received', 'Reg No.', 'Code', 'Outcome', 'Distance', 'State', 'Source', 'Attempted'].map(h => (
                  <th key={h} style={th}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map(a => {
                const waiting = a.awaiting_session && !a.resolved_at
                return (
                  <tr key={a.attempt_id} style={{ borderBottom: '1px solid var(--border,#f1f5f9)' }}>
                    <td style={{ ...td, whiteSpace: 'nowrap' }}>{new Date(a.received_at).toLocaleString()}</td>
                    <td style={{ ...td, fontFamily: 'monospace', fontSize: 12 }}>{a.student_id || '—'}</td>
                    <td style={{ ...td, fontFamily: 'monospace', fontSize: 12 }}>{a.session_code || '—'}</td>
                    <td style={{ ...td, color: a.outcome === 'REJECTED' ? '#b91c1c' : a.outcome === 'PRESENT' ? '#16a34a' : '#b45309', fontWeight: 600 }}>
                      {a.outcome}
                    </td>
                    <td style={td}>{a.distance_meters == null ? '—' : `${a.distance_meters} m`}</td>
                    <td style={td}>
                      {waiting
                        ? <span style={{ background: '#fef3c7', color: '#92400e', padding: '2px 8px', borderRadius: 999, fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap' }}>waiting {age(a.received_at)}</span>
                        : a.resolved_at
                          ? <span style={{ background: '#dcfce7', color: '#166534', padding: '2px 8px', borderRadius: 999, fontSize: 12, fontWeight: 600, whiteSpace: 'nowrap' }}>resolved</span>
                          : <span style={td}>{a.outcome}</span>}
                    </td>
                    <td style={td}>{a.captured_offline ? 'offline queue' : 'live'}</td>
                    <td style={{ ...td, whiteSpace: 'nowrap', color: 'var(--muted)' }}>{new Date(a.attempted_at).toLocaleString()}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function age(iso: string): string {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m`
  return `${Math.floor(m / 60)}h ${m % 60}m`
}

function Kpi({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div style={{ background: 'var(--surface,#fff)', border: '1px solid var(--border,#e2e8f0)', borderRadius: 10, padding: '10px 18px' }}>
      <div style={{ fontSize: 22, fontWeight: 800, color: tone }}>{value}</div>
      <div style={{ fontSize: 11, color: 'var(--muted)', fontWeight: 600 }}>{label}</div>
    </div>
  )
}

const th: React.CSSProperties = { padding: '8px 10px', fontWeight: 600, fontSize: 12, color: 'var(--muted)' }
const td: React.CSSProperties = { padding: '7px 10px' }
const inp: React.CSSProperties = { padding: '6px 10px', border: '1px solid var(--border,#cbd5e1)', borderRadius: 6, fontSize: 13, background: 'var(--surface,#fff)', color: 'var(--text)' }
const btn: React.CSSProperties = { padding: '7px 16px', background: '#1e293b', color: '#fff', border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 600, fontSize: 13 }