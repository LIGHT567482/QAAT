import { useState } from 'react'
import { api } from '../../lib/api'
import { useQuery } from '../../lib/useApi'

/**
 * EVERY CHECK-IN THAT WAS TRIED, INCLUDING THE ONES THAT FAILED.
 *
 * QAAT used to reject a check-in and keep nothing. The student saw a message and the system
 * retained no evidence they had ever tried — so the commonest attendance dispute, "I was there and
 * it would not mark me present", had nothing to examine on either side. An absence caused by a
 * failed attempt looked exactly like an absence caused by not turning up.
 *
 * This is that evidence. It answers two questions and the filters are the questions:
 *
 *   Whose register went wrong — forty refusals at 1600 metres is not forty student problems, it is
 *   ONE session opened at the wrong coordinates, and it is invisible in the register itself.
 *
 *   What happened to this student — one refusal at 1520 metres reads very differently from twenty
 *   in a minute from three kilometres away.
 *
 * Accepted attempts are shown by default alongside refused ones. A view of failures alone would
 * answer "were there problems" but not "what share of attempts were problems", and forty refusals
 * mean something different in a hall of forty than in a hall of four hundred.
 */
interface Attempt {
  attempt_id: string
  session_id: string
  student_id: string
  session_code: string
  outcome: 'PRESENT' | 'DUPLICATE' | 'REJECTED' | string
  reason: string
  distance_meters: number | null
  device_id: string
  captured_offline: boolean
  attempted_at: string
}
interface Resp { attempts: Attempt[]; total: number; accepted: number; refused: number; days: number }

export default function CheckinAttempts() {
  const [days, setDays] = useState(7)
  const [failedOnly, setFailedOnly] = useState(false)
  const [student, setStudent] = useState('')

  const { status, data, refetch } = useQuery<Resp>(
    () => api.get(`/api/v1/attendance/attempts?days=${days}`
      + (failedOnly ? '&failed_only=true' : '')
      + (student.trim() ? `&student_id=${encodeURIComponent(student.trim())}` : '')),
    [days, failedOnly, student],
  )
  const rows = status === 'ok' ? (data?.attempts ?? []) : []

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6, flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h2 style={{ margin: 0 }}>Check-in Attempts</h2>
          <p style={{ color: 'var(--muted)', margin: '4px 0 0', fontSize: 13 }}>
            Every attempt, accepted or refused, with why and how far away the student was. This is
            what answers “I was there and it would not let me”.
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <input placeholder="Registration number" value={student} onChange={e => setStudent(e.target.value)} style={inp} />
          <select value={days} onChange={e => setDays(Number(e.target.value))} style={inp}>
            <option value={1}>Today</option>
            <option value={7}>Last 7 days</option>
            <option value={30}>Last 30 days</option>
          </select>
          <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
            <input type="checkbox" checked={failedOnly} onChange={e => setFailedOnly(e.target.checked)} />
            Refused only
          </label>
          <button onClick={refetch} style={btn}>Refresh</button>
        </div>
      </div>

      {status === 'loading' && <p style={{ color: 'var(--muted)' }}>Loading…</p>}
      {status === 'error' && <p style={{ color: '#b91c1c' }}>Failed to load attempts.</p>}

      {data && (
        <div style={{ display: 'flex', gap: 12, margin: '16px 0' }}>
          <Kpi label="Attempts" value={data.total} tone="#475569" />
          <Kpi label="Accepted" value={data.accepted} tone="#16a34a" />
          {/* The number worth acting on: a high refusal count is usually one broken session. */}
          <Kpi label="Refused" value={data.refused} tone={data.refused > 0 ? '#dc2626' : '#16a34a'} />
        </div>
      )}

      {status === 'ok' && rows.length === 0 && (
        <p style={{ color: 'var(--muted)', textAlign: 'center', marginTop: 40 }}>
          No check-in attempts in this window.
        </p>
      )}

      {rows.length > 0 && (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13, minWidth: 720 }}>
            <thead>
              <tr style={{ background: 'var(--surface,#f8fafc)', textAlign: 'left' }}>
                {['When', 'Reg No.', 'Code', 'Outcome', 'Distance', 'Why', 'Source'].map(h => (
                  <th key={h} style={th}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map(a => {
                const bad = a.outcome === 'REJECTED'
                return (
                  <tr key={a.attempt_id} style={{ borderBottom: '1px solid var(--border,#f1f5f9)' }}>
                    <td style={{ ...td, whiteSpace: 'nowrap' }}>{new Date(a.attempted_at).toLocaleString()}</td>
                    <td style={{ ...td, fontFamily: 'monospace', fontSize: 12 }}>{a.student_id || '—'}</td>
                    <td style={{ ...td, fontFamily: 'monospace', fontSize: 12 }}>{a.session_code || '—'}</td>
                    <td style={{ ...td, color: bad ? '#b91c1c' : a.outcome === 'PRESENT' ? '#16a34a' : '#b45309', fontWeight: 600 }}>
                      {a.outcome}
                    </td>
                    {/* Distance is the fact a dispute turns on, so it is a column and not a tooltip. */}
                    <td style={td}>{a.distance_meters == null ? '—' : `${a.distance_meters} m`}</td>
                    <td style={{ ...td, color: 'var(--muted)' }}>{a.reason || '—'}</td>
                    <td style={td}>{a.captured_offline ? 'offline queue' : 'live'}</td>
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
