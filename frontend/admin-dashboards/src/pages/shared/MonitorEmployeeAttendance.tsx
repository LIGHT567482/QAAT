import { useMemo, useState } from 'react'
import { api } from '../../lib/api'
import { useQuery } from '../../lib/useApi'
import ExportButtons from '../../components/ExportButtons'

/**
 * Employee attendance — QA OFFICE ROUND record.
 *
 * The independent human witness. Every other record of an employee's presence in this system is a
 * machine's: badge punches from the tablet, campus presence from U-Panel, and the biometric
 * terminal's daily sheet. A badge can be tapped by a colleague, and the terminal saying somebody
 * clocked in at 08:00 says nothing about whether they were at their desk at 11:00.
 *
 * This is what a QA monitor found on walking to the office. It is kept on its own tab and never
 * merged with the terminal sheet, for the same reason the monitor's lecture record is kept apart
 * from the coordinator's: where the two disagree is the finding, and merging would hide it.
 *
 * THREE VERDICTS, NOT TWO. "Elsewhere, on duty" exists so a monitor who established that somebody
 * was at a meeting is not forced to file them as absent — which would be a false accusation
 * against somebody who was working, and only "Office empty" is ever reported to the person.
 */
interface Summary {
  staff_id: string; employee_name: string; department: string; office: string
  visits: number; at_office: number; elsewhere: number; absent: number
  rate: number; last_visit_date: string
}
interface Visit {
  visit_id: string; staff_id: string; employee_name: string; department: string; job_title: string
  office: string; office_source: 'REGISTRY' | 'TYPED'
  status: 'AT_OFFICE' | 'ELSEWHERE_ON_DUTY' | 'ABSENT'
  found_at: string; remarks: string
  visit_date: string; visit_time: string
  qa_monitor: string; qa_monitor_staff_id: string
  captured_at: string; received_at: string
}

// Named for a reader, not for the database — and ABSENT deliberately does not read as "Absent".
// One knock establishes that a door was empty at a minute; it does not establish absence from
// work, and this label is what ends up in front of the person's head of department.
const VERDICT: Record<Visit['status'], { label: string; bg: string; fg: string }> = {
  AT_OFFICE: { label: 'At office', bg: '#f0fdf4', fg: '#166534' },
  ELSEWHERE_ON_DUTY: { label: 'Elsewhere', bg: '#eff6ff', fg: '#1e40af' },
  ABSENT: { label: 'Office empty', bg: '#fef2f2', fg: '#b91c1c' },
}

export default function MonitorEmployeeAttendance() {
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [dept, setDept] = useState('')
  const [q, setQ] = useState('')
  const [status_, setStatus] = useState('')   // '' | AT_OFFICE | ELSEWHERE_ON_DUTY | ABSENT

  // Applied filters are separate from the inputs, so typing a name does not fire a query per
  // keystroke — the same arrangement the terminal-sheet tab uses beside this one.
  const [applied, setApplied] = useState({ from: '', to: '', department: '', q: '', status: '' })

  const query = useMemo(() => {
    const p: Record<string, string> = {}
    if (applied.from) p.from = applied.from
    if (applied.to) p.to = applied.to
    if (applied.department) p.department = applied.department
    if (applied.q) p.q = applied.q
    if (applied.status) p.status = applied.status
    return p
  }, [applied])

  const qs = new URLSearchParams(query).toString()
  const { data, status } = useQuery<{
    summary: Summary[]; visits: Visit[]; departments: string[]; count: number
  }>(() => api.get(`/api/v1/dashboard/employee-attendance/patrol${qs ? `?${qs}` : ''}`), [qs])

  const summary = data?.summary ?? []
  const visits = data?.visits ?? []

  const [open, setOpen] = useState<Set<string>>(new Set())
  const toggle = (id: string) => setOpen(p => { const n = new Set(p); n.has(id) ? n.delete(id) : n.add(id); return n })
  const visitsFor = (id: string) => visits.filter(v => v.staff_id === id)

  const apply = () => setApplied({ from, to, department: dept, q, status: status_ })
  const clear = () => {
    setFrom(''); setTo(''); setDept(''); setQ(''); setStatus('')
    setApplied({ from: '', to: '', department: '', q: '', status: '' })
  }

  const totals = summary.reduce(
    (a, s) => ({ v: a.v + s.visits, e: a.e + s.absent }), { v: 0, e: 0 })
  const fmtDate = (d: string) => d ? new Date(d + 'T00:00:00').toLocaleDateString() : '—'

  return (
    <div style={{ color: 'var(--text)' }}>
      <p style={{ color: 'var(--muted)', margin: '0 0 12px', fontSize: 13, maxWidth: 660 }}>
        What a QA monitor found on walking to the office — the one record here that a person made
        rather than a device. Filed beside the terminal sheet, never merged with it. One row per
        employee; open it for every visit.
      </p>

      <div style={{
        display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap',
        background: 'var(--surface-2,#f8fafc)', border: '1px solid var(--border,#e2e8f0)',
        borderRadius: 10, padding: 14, marginBottom: 16,
      }}>
        <label><div style={lbl}>From</div>
          <input type="date" value={from} onChange={e => setFrom(e.target.value)} style={inp} /></label>
        <label><div style={lbl}>To</div>
          <input type="date" value={to} onChange={e => setTo(e.target.value)} style={inp} /></label>
        <label><div style={lbl}>Department</div>
          <select value={dept} onChange={e => setDept(e.target.value)} style={{ ...inp, minWidth: 180 }}>
            <option value="">All departments</option>
            {(data?.departments ?? []).map(d => <option key={d} value={d}>{d}</option>)}
          </select></label>
        <label><div style={lbl}>Name or staff ID</div>
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="e.g. NAKATO, or KIU/044"
            style={{ ...inp, minWidth: 190 }} /></label>
        <label><div style={lbl}>Show only</div>
          <select value={status_} onChange={e => setStatus(e.target.value)} style={{ ...inp, minWidth: 170 }}>
            <option value="">Every visit</option>
            <option value="ABSENT">Office empty</option>
            <option value="ELSEWHERE_ON_DUTY">Elsewhere, on duty</option>
            <option value="AT_OFFICE">At their office</option>
          </select></label>
        <button onClick={apply} style={btnPrimary}>Apply</button>
        <button onClick={clear} style={btnGhost}>Clear</button>
      </div>

      <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginBottom: 10, flexWrap: 'wrap' }}>
        <span style={{ fontSize: 13, color: 'var(--muted)' }}>
          {status === 'loading'
            ? 'Loading…'
            : `${totals.v} visit${totals.v === 1 ? '' : 's'}${totals.e > 0 ? ` · ${totals.e} found the office empty` : ''}`}
        </span>
        {/* The export inherits the current filters, so it is the same set of visits. */}
        <ExportButtons base="/api/v1/dashboard/employee-attendance/patrol/export"
          filename="employee-office-round" query={qs} disabled={visits.length === 0} />
      </div>

      {status === 'ok' && summary.length === 0 && (
        <div style={{ background: '#fffbeb', border: '1px solid #fde68a', color: '#92400e', borderRadius: 10, padding: 16, fontSize: 13 }}>
          No office visits recorded yet. Records appear here once a QA monitor walks a round and
          syncs it from the phone app.
        </div>
      )}

      {summary.length > 0 && (
        <div style={{ overflowX: 'auto' }}>
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 14 }}>
            <thead><tr style={{ background: 'var(--surface,#f8fafc)' }}>
              {['Employee', 'Staff ID', 'Department', 'Office', 'Visits', 'At office', 'Elsewhere', 'Empty', 'Rate', 'Last visit', ''].map(h =>
                <th key={h} style={{ padding: '8px 12px', textAlign: 'left', borderBottom: '1px solid var(--border,#e2e8f0)', whiteSpace: 'nowrap' }}>{h}</th>)}
            </tr></thead>
            <tbody>
              {summary.map(s => (
                <>
                  <tr key={s.staff_id} style={{ borderBottom: open.has(s.staff_id) ? 'none' : '1px solid var(--border,#f1f5f9)' }}>
                    <td style={{ padding: '10px 12px', fontWeight: 700 }}>{s.employee_name || s.staff_id}</td>
                    <td style={{ padding: '10px 12px', fontFamily: 'monospace', fontSize: 12 }}>{s.staff_id}</td>
                    <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>{s.department || '—'}</td>
                    <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>{s.office || '—'}</td>
                    <td style={{ padding: '10px 12px', fontWeight: 700 }}>{s.visits}</td>
                    <td style={{ padding: '10px 12px', color: '#15803d', fontWeight: 600 }}>{s.at_office}</td>
                    <td style={{ padding: '10px 12px', color: '#1e40af' }}>{s.elsewhere}</td>
                    <td style={{ padding: '10px 12px', color: s.absent > 0 ? '#b91c1c' : 'var(--muted)', fontWeight: s.absent > 0 ? 700 : 400 }}>{s.absent}</td>
                    <td style={{ padding: '10px 12px' }}>
                      <span style={{ fontWeight: 700, color: s.rate >= 75 ? '#15803d' : '#b91c1c' }}>{s.rate}%</span>
                    </td>
                    <td style={{ padding: '10px 12px', color: 'var(--muted)' }}>{fmtDate(s.last_visit_date)}</td>
                    <td style={{ padding: '10px 12px' }}>
                      <button onClick={() => toggle(s.staff_id)} style={btnGhost}>
                        {open.has(s.staff_id) ? 'Hide visits' : 'View visits'}
                      </button>
                    </td>
                  </tr>
                  {open.has(s.staff_id) && (
                    <tr key={`${s.staff_id}-v`}><td colSpan={11} style={{ padding: '0 12px 14px', background: 'var(--surface,#f8fafc)' }}>
                      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                        <thead><tr>{['Date', 'Time', 'Office', 'Found', 'Where instead', 'Remarks', 'QA Monitor', 'Recorded'].map(h =>
                          <th key={h} style={{ padding: '6px 10px', textAlign: 'left', color: 'var(--muted)' }}>{h}</th>)}</tr></thead>
                        <tbody>
                          {visitsFor(s.staff_id).map(v => {
                            const verdict = VERDICT[v.status] ?? { label: v.status, bg: 'var(--surface,#f8fafc)', fg: 'var(--text)' }
                            return (
                              <tr key={v.visit_id} style={{ borderTop: '1px solid var(--border,#e8eef4)' }}>
                                <td style={{ padding: '6px 10px', fontWeight: 600 }}>{fmtDate(v.visit_date)}</td>
                                <td style={{ padding: '6px 10px' }}>{v.visit_time || '—'}</td>
                                <td style={{ padding: '6px 10px' }}>
                                  {v.office || '—'}
                                  {/* An office the monitor had to type is one the registry has
                                      wrong — a run of these for one department is a registry to fix. */}
                                  {v.office_source === 'TYPED' && (
                                    <span style={{ color: 'var(--muted)', fontSize: 11, marginLeft: 6 }}>typed</span>
                                  )}
                                </td>
                                <td style={{ padding: '6px 10px' }}>
                                  <span style={{
                                    padding: '2px 8px', borderRadius: 999, fontSize: 11, fontWeight: 700,
                                    background: verdict.bg, color: verdict.fg,
                                  }}>{verdict.label}</span>
                                </td>
                                <td style={{ padding: '6px 10px' }}>{v.found_at || '—'}</td>
                                <td style={{ padding: '6px 10px', color: 'var(--muted)' }}>{v.remarks || '—'}</td>
                                <td style={{ padding: '6px 10px' }}>
                                  {v.qa_monitor || '—'}
                                  {v.qa_monitor_staff_id &&
                                    <span style={{ color: 'var(--muted)', fontSize: 11, marginLeft: 6 }}>{v.qa_monitor_staff_id}</span>}
                                </td>
                                <td style={{ padding: '6px 10px', color: 'var(--muted)' }}>
                                  {v.captured_at ? new Date(v.captured_at).toLocaleString() : '—'}
                                </td>
                              </tr>
                            )
                          })}
                          {visitsFor(s.staff_id).length === 0 && (
                            <tr><td colSpan={8} style={{ padding: 12, color: 'var(--muted)' }}>No visits in this range.</td></tr>
                          )}
                        </tbody>
                      </table>
                    </td></tr>
                  )}
                </>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

const lbl: React.CSSProperties = { fontSize: 11, fontWeight: 700, color: 'var(--muted)', marginBottom: 3 }
const inp: React.CSSProperties = { padding: '8px 10px', borderRadius: 8, border: '1px solid var(--border,#e2e8f0)', fontSize: 13 }
const btnPrimary: React.CSSProperties = { padding: '8px 16px', background: 'var(--brand)', color: 'var(--brand-contrast,#fff)', border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 600, fontSize: 13 }
const btnGhost: React.CSSProperties = { padding: '8px 12px', background: 'transparent', color: 'var(--text,#334155)', border: '1px solid var(--border,#e2e8f0)', borderRadius: 6, cursor: 'pointer', fontSize: 13 }
