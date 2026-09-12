import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { Navigate, Outlet, useLocation, useNavigate } from 'react-router-dom'
import DashboardWelcome from '../components/DashboardWelcome'
import { InstallPwaButton } from '../components/InstallPwaButton'
import { useAuth, type Role } from '../contexts/AuthContext'
import { api } from '../lib/api'
import PasswordInput from '../components/PasswordInput'
import { useMediaQuery } from '../lib/useMediaQuery'
import { type Theme, useTheme, ThemeToggle, applyPalette } from '../theme'
import brandDefault from '../brand.json'

interface Branding {
  name: string; logo_url: string; motto: string
  brand_color: string; sidebar_color: string; background_color: string; footer_color: string
  text_color_light?: string; text_color_dark?: string
}

// The bundled brand.json is the single source of truth for identity, so the sidebar
// shows the real KIU logo + name from the first frame (never the "Q" letter). The
// backend /branding fetch below simply confirms it.
const BUNDLED_BRAND = brandDefault as unknown as Branding

interface RoleLayoutProps {
  allowedRoles: Role[]
}

// Wraps a route group — redirects to /login if unauthenticated or wrong role.
export function RoleLayout({ allowedRoles }: RoleLayoutProps) {
  const { user, isAuthenticated } = useAuth()
  const [brand, setBrand] = useState<Branding | null>(BUNDLED_BRAND)
  const navigate = useNavigate()
  const location = useLocation()
  const { theme, toggle } = useTheme()

  // Narrow screen (a phone): the fixed sidebar folds into a drawer behind a hamburger,
  // because squishing a 220px desktop column into 375px was never going to be readable.
  const isMobile = useMediaQuery('(max-width: 959px)')
  const [navOpen, setNavOpen] = useState(false)
  useEffect(() => {
    if (!isMobile) setNavOpen(false)
  }, [isMobile])

  // Start on the bundled brand (instant logo + palette), then let the backend
  // /branding fetch confirm/refresh it. On failure we keep the bundled brand.
  useEffect(() => {
    applyPalette(BUNDLED_BRAND)
    if (!isAuthenticated) return
    api.get<Branding>('/api/v1/branding').then(b => { setBrand(b); applyPalette(b) }).catch(() => {})
  }, [isAuthenticated])

  if (!isAuthenticated || !user) {
    return <Navigate to="/login" replace />
  }
  if (!allowedRoles.includes(user.role)) {
    return <Navigate to="/unauthorized" replace />
  }
  return (
    // app-shell = min-height:100dvh (with 100vh fallback) so the footer always sits at
    // the bottom of the visible viewport, on phones too. No margins → full-bleed.
    <div className="app-shell" style={{ display: 'flex', fontFamily: 'system-ui' }}>
      {/* Desktop: the sidebar column beside the content. */}
      {!isMobile && <Sidebar role={user.role} brand={brand} />}

      {/* Mobile: a sticky top bar with the menu button and the institution mark. */}
      {isMobile && (
        <MobileTopBar
          brand={brand}
          role={user.role}
          theme={theme}
          toggle={toggle}
          onMenu={() => setNavOpen(true)}
        />
      )}
      {/* Mobile: the sidebar as a drawer behind a tap-to-close backdrop. Full navigation
          links are <a href> (full page loads), so tapping one already lands on the new
          page with the drawer closed. */}
      {isMobile && navOpen && (
        <>
          <div
            onClick={() => setNavOpen(false)}
            style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.45)', zIndex: 40 }}
          />
          <div style={{
            position: 'fixed', top: 0, left: 0, bottom: 0, width: 'min(82vw, 280px)',
            zIndex: 41, boxShadow: '2px 0 14px rgba(0,0,0,.3)',
          }}>
            <Sidebar role={user.role} brand={brand} />
          </div>
        </>
      )}

      {/* Content column fills the rest and carries the tenant background colour. */}
      <div style={{
        flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', background: 'var(--app-bg)', position: 'relative',
      }}>
        {/* Faint institution logo watermark, behind every page's content. Centred on
            phones (no sidebar to offset against). */}
        {brand?.logo_url && (
          <img src={brand.logo_url} alt="" aria-hidden style={{
            position: 'fixed', top: '50%', left: isMobile ? '50%' : 'calc(50% + 110px)', transform: 'translate(-50%, -50%)',
            width: '42vmin', maxWidth: 520, opacity: 0.05, pointerEvents: 'none', zIndex: 0, userSelect: 'none',
          }} />
        )}
        <main style={{ flex: 1, padding: isMobile ? 12 : 24, color: 'var(--text)', position: 'relative', zIndex: 1 }}>
          <GoBack navigate={navigate} location={location} />
          {/* Every dashboard greets the person by title and name. Rendered here rather
              than per page, so a new dashboard gets it by existing. */}
          <DashboardWelcome />
          <Outlet />
        </main>
        <footer style={{ background: 'var(--footer)', color: 'var(--footer-text)', padding: '12px 24px', fontSize: 12, textAlign: 'center', position: 'relative', zIndex: 1 }}>
          {brand?.name ? `${brand.name} · ` : ''}Powered by LIGHT TECHNOLOGIES
        </footer>
      </div>
    </div>
  )
}

type NavLink = { label: string; path: string }

// ── WHAT IS AND IS NOT IN v1 ────────────────────────────────────────────────────────────────
// v1 is an INTERNAL Quality Assurance console: lecturer attendance, employee attendance, the QA
// monitor round, the timetable and the reports drawn from them. Two modules are deferred to v2 —
// everything to do with STUDENTS, and the U-PANEL integration — and their entries below are
// commented out rather than deleted, so restoring the module is uncommenting its line here, its
// route in App.tsx, and its route in the gateway. The pages themselves are untouched.
const NAV: Record<Role, NavLink[]> = {

  VC: [
    { label: 'Overview',            path: '/vc' },
    { label: 'Lecturer Workload',   path: '/vc/lecturer-workload' },
    { label: 'Lecturer Attendance', path: '/vc/lecturer-attendance' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/vc/student-attendance' },
    { label: 'Check-in Attempts',   path: '/vc/checkin-attempts' },
    { label: 'Pending Sync',        path: '/vc/pending-sync' },
    { label: 'Timetable',           path: '/vc/timetable' },
    { label: 'Free Rooms',          path: '/vc/free-rooms' },
    { label: 'Messages & Alerts',   path: '/vc/messages' },
    { label: 'Employee Attendance', path: '/vc/employee-attendance' },
  ],
  // The directorate's own sidebar. Kept in the order the work is actually done: what the rules
  // ARE, then who is falling outside them, then where that is happening, then the QA round that
  // produced the evidence, then the people to talk to about it.
  //
  // Three of these were pages that already existed and were simply unreachable — Alerts and
  // Employee Attendance had routes in App.tsx and no sidebar entry at all, and the at-risk
  // watchlist was given to every other oversight role but not to the one that sets the threshold.
  // A page nobody can navigate to is, from the director's chair, a page that does not exist.
  DQA_DIRECTOR: [
    // Reports leads: it is the map of everything below, and the answer to "where do I get X"
    // should be the first thing in the list rather than something you learn by exploring it.
    { label: 'Home',                path: '/dqa' },
    { label: 'Reports',             path: '/dqa/reports' },
    // DEFERRED TO V2 — { label: 'Eligibility',         path: '/dqa/eligibility' },
    // DEFERRED TO V2 — { label: 'Unit Attendance',     path: '/dqa/unit-attendance' },
    // DEFERRED TO V2 — { label: 'At-risk Students',    path: '/dqa/at-risk' },
    // DEFERRED TO V2 — { label: 'Course Health',       path: '/dqa/course-health' },
    { label: 'By College',          path: '/dqa/org' },
    { label: 'Punctuality',         path: '/dqa/punctuality' },
    { label: 'Lecturer Attendance', path: '/dqa/lecturer-attendance' },
    { label: 'QA Monitor Coverage', path: '/dqa/monitor-coverage' },
    { label: 'Timetable',           path: '/dqa/timetable' },
    { label: 'Free Rooms',          path: '/dqa/free-rooms' },
    { label: 'Presence Disputes',   path: '/dqa/presence-claims' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/dqa/student-attendance' },
    { label: 'Check-in Attempts',   path: '/dqa/checkin-attempts' },
    { label: 'Pending Sync',        path: '/dqa/pending-sync' },
    { label: 'Employee Attendance', path: '/dqa/employee-attendance' },
    { label: 'QA Reports',          path: '/dqa/qa-reports' },
    { label: 'Messages & Alerts',   path: '/dqa/messages' },
  ],
  QA_OFFICER: [
    { label: 'QA Reports',          path: '/qa/reports' },
    { label: 'Timetable',           path: '/qa/timetable' },
    { label: 'Free Rooms',          path: '/qa/free-rooms' },
    { label: 'Employee Attendance', path: '/qa/employee-attendance' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/qa/student-attendance' },
    { label: 'Check-in Attempts',   path: '/qa/checkin-attempts' },
    { label: 'Pending Sync',        path: '/qa/pending-sync' },
    { label: 'Lecturer Attendance', path: '/qa/lecturer-attendance' },
    // DEFERRED TO V2 — Manual Correction writes STUDENT attendance.
    // { label: 'Manual Correction',   path: '/qa/correction' },

    { label: 'Coordinator Health',  path: '/qa/coordinator-health' },
    { label: 'Presence Disputes',   path: '/qa/presence-claims' },
    // DEFERRED TO V2 — { label: 'Device Resets',       path: '/qa/device-reset' },
    { label: 'Messages & Alerts',   path: '/qa/messages' },
  ],
  COORDINATOR: [],
  // Empty for the same reason as COORDINATOR: a lecturer's work is in the room, on the phone.
  // Kept as an entry rather than dropped from the Role union, because the role still exists,
  // still signs in, and Login names the app for them — it just has no pages here.
  LECTURER: [],
  ADMIN: [], // built in adminNav() below.
  // HOD and DEAN each had exactly ONE page — a lecturer list — which is why the two roles
  // responsible for a department and a college could see less than the QA rep who visits it.
  // They now open on an overview of their own unit and carry the pages that make it actionable.
  HOD: [
    { label: 'Overview',            path: '/hod' },
    { label: 'Lecturers',           path: '/hod/lecturers' },
    // DEFERRED TO V2 — { label: 'At-risk Students',    path: '/hod/at-risk' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/hod/attendance' },
    { label: 'Assignments',         path: '/hod/assignments' },
    { label: 'Timetable',           path: '/hod/timetable' },
    { label: 'Messages & Alerts',   path: '/hod/messages' },
  ],
  DEAN: [
    { label: 'Overview',            path: '/dean' },
    { label: 'Departments & Heads', path: '/dean/departments' },
    { label: 'Lecturers',           path: '/dean/lecturers' },
    // DEFERRED TO V2 — { label: 'At-risk Students',    path: '/dean/at-risk' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/dean/attendance' },
    { label: 'Timetable',           path: '/dean/timetable' },
    { label: 'Messages & Alerts',   path: '/dean/messages' },
  ],
  QA_DEPT_REP: [
    { label: 'Overview',       path: '/qa-dept' },
    { label: 'Lecturers',      path: '/qa-dept/lecturers' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/qa-dept/student-attendance' },
    { label: 'Lecturer Attendance', path: '/qa-dept/lecturer-attendance' },
    // DEFERRED TO V2 — { label: 'At-risk Students', path: '/qa-dept/at-risk' },
    { label: 'File QA Report', path: '/qa-dept/report' },
    { label: 'Timetable',      path: '/qa-dept/timetable' },
    { label: 'Messages & Alerts', path: '/qa-dept/messages' },
  ],
  // The Teaching & Learning Centre owns the timetable and nothing else — a
  // deliberately narrow console, because that is the whole of the role.
  TLC: [
    { label: 'Timetable',       path: '/tlc' },
    { label: 'Rooms',           path: '/tlc/rooms' },
    { label: 'Free Rooms',      path: '/tlc/free-rooms' },
  ],
  // These two work from the phone, not here. Empty rather than absent so the map covers the
  // whole Role union and a new role cannot be forgotten silently.
  QA_PATROLLER: [],
  STUDENT: [],
  QA_SCHOOL_HANDLER: [
    { label: 'Overview',        path: '/qa-school' },
    { label: 'Departments & Heads', path: '/qa-school/departments' },
    { label: 'QA Coverage',     path: '/qa-school/qa-departments' },
    { label: 'Lecturers',       path: '/qa-school/lecturers' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: '/qa-school/student-attendance' },
    { label: 'Lecturer Attendance', path: '/qa-school/lecturer-attendance' },
    // DEFERRED TO V2 — { label: 'At-risk Students', path: '/qa-school/at-risk' },
    { label: 'QA Reports',      path: '/qa-school/reports' },
    { label: 'Presence Disputes', path: '/qa-school/presence-claims' },
    { label: 'Timetable',       path: '/qa-school/timetable' },
    { label: 'Messages & Alerts', path: '/qa-school/messages' },
  ],
}

// The ADMIN sidebar lists EVERY management page so nothing is buried behind the
// home grid. The sub-resource pages are keyed by the admin's own tenant_id.
function adminNav(): NavLink[] {
  const t = `/admin`
  return [
    { label: 'Home',                path: '/admin' },
    { label: 'Administration',      path: `${t}/users` },
    { label: 'Schools & Departments', path: `${t}/schools` },
    { label: 'Courses & Sessions',  path: `${t}/courses` },
    { label: 'Timetable',           path: '/admin/timetable' },
    // DEFERRED TO V2 — { label: 'Students',            path: `${t}/students` },
    { label: 'Coordinators',        path: `${t}/coordinators` },
    { label: 'Lecturers',           path: `${t}/lecturers` },
    { label: 'Assignments',         path: `${t}/lecturer-assignments` },
    { label: 'Lecturer Attendance', path: `${t}/lecturer-attendance` },
    { label: 'Check-in Attempts',   path: '/admin/checkin-attempts' },
    { label: 'Pending Sync',        path: '/admin/pending-sync' },
    // DEFERRED TO V2 — { label: 'Student Attendance',  path: `${t}/student-attendance` },
    { label: 'Employees',           path: `${t}/employees` },
    // DEFERRED TO V2 — { label: 'At-risk Students',    path: '/admin/at-risk' },
    { label: 'Reports',             path: '/admin/reports' },
    { label: 'Rooms & Codes',       path: `${t}/rooms` },
    { label: 'Free Rooms',          path: '/admin/free-rooms' },
    // The trail of who did what. It has been written to since the audit helper landed; before
    // that the table existed and nothing ever wrote a row to it.
    { label: 'Audit Trail',         path: '/admin/audit' },
    // ADMIN has always been in the gateway's inboxRoles, so notices addressed to the
    // administrator were being delivered and had nowhere here to be read.
    { label: 'Messages & Alerts',   path: '/admin/messages' },
    { label: 'Settings',            path: '/admin/settings' },
  ]
}

function Sidebar({ role, brand }: { role: Role; brand: Branding | null }) {
  const { logout } = useAuth()
  const { theme, toggle } = useTheme()
  const [pwOpen, setPwOpen] = useState(false)
  const links = role === 'ADMIN' ? adminNav() : (NAV[role] ?? [])
  const current = typeof window !== 'undefined' ? window.location.pathname : ''

  // Unread-messages badge for the roles that have a Messages inbox. Polls, and refetches
  // on navigation (so it clears after the user reads their inbox).
  const [unread, setUnread] = useState(0)
  useEffect(() => {
    // Every role with a Messages inbox polls the badge — the three QA field roles share the
    // DQA channel, so they all have one.
    const withInbox: Role[] = ['DQA_DIRECTOR', 'QA_OFFICER', 'QA_DEPT_REP', 'QA_SCHOOL_HANDLER']
    if (!withInbox.includes(role)) return
    let alive = true
    const fetchUnread = () => api.get<{ unread: number }>('/api/v1/messages/unread-count')
      .then(r => { if (alive) setUnread(r.unread || 0) }).catch(() => {})
    fetchUnread()
    const id = setInterval(fetchUnread, 20000)
    return () => { alive = false; clearInterval(id) }
  }, [role, current])

  const name = brand?.name || 'QAAT'

  return (
    <aside style={{
      width: 220, flexShrink: 0, background: 'var(--sidebar)', color: 'var(--sidebar-text)',
      display: 'flex', flexDirection: 'column', padding: '24px 0',
      position: 'sticky', top: 0, alignSelf: 'flex-start', height: '100dvh', overflowY: 'auto',
    }}>
      <div style={{ padding: '0 20px 24px', borderBottom: '1px solid rgba(255,255,255,.12)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          {brand?.logo_url
            ? <img src={brand.logo_url} alt={name} style={{ height: 64, width: 64, objectFit: 'contain', borderRadius: 6 }} />
            : <div style={{
                height: 64, width: 64, borderRadius: 6, background: 'var(--brand)',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700,
              }}>{name.slice(0, 1)}</div>}
          {/* The product beside the mark, then the institution beneath it. The header used to
              name only the institution, so every dashboard said whose system it was and none of
              them said what it was — while the browser tab said "KIU QAAT". Same order as the
              phone app's BrandHeader, so the two read as one system. */}
          <div style={{ minWidth: 0 }}>
            <strong style={{ fontSize: 17, display: 'block', lineHeight: 1.15 }}>KIU QAAT</strong>
            <span style={{ fontSize: 11, opacity: .8, display: 'block', marginTop: 2 }}>{name}</span>
          </div>
        </div>
        {brand?.motto && <div style={{ fontSize: 11, opacity: .75, marginTop: 6, fontStyle: 'italic' }}>{brand.motto}</div>}
        <div style={{ fontSize: 12, opacity: .75, marginTop: 4 }}>{role.replace('_', ' ')}</div>
      </div>
      <nav style={{ flex: 1, padding: '16px 0', overflowY: 'auto' }}>
        {links.map(l => {
          const active = l.path === '/admin'
            ? current === '/admin'
            : current === l.path || current.startsWith(l.path + '/')
          return (
            <a key={l.path} href={l.path} style={{
              display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8,
              padding: '10px 20px', color: 'var(--sidebar-text)',
              opacity: active ? 1 : .82, textDecoration: 'none', fontSize: 14,
              fontWeight: active ? 700 : 400,
              background: active ? 'rgba(255,255,255,.16)' : 'transparent',
              borderLeft: active ? '3px solid var(--brand)' : '3px solid transparent',
            }}>
              <span>{l.label}</span>
              {l.path.endsWith('/messages') && unread > 0 && (
                <span style={{
                  background: '#ef4444', color: '#fff', borderRadius: 999, fontSize: 10,
                  fontWeight: 700, padding: '1px 7px', minWidth: 18, textAlign: 'center',
                }}>{unread > 99 ? '99+' : unread}</span>
              )}
            </a>
          )
        })}
      </nav>
      <div style={{ margin: '0 16px 8px' }}>
        <InstallPwaButton />
      </div>
      <div style={{ margin: '0 16px 8px' }}>
        <button onClick={() => setPwOpen(true)} style={{
          width: '100%', padding: '9px', background: 'transparent', color: 'var(--sidebar-text)',
          border: '1px solid rgba(255,255,255,.25)', borderRadius: 6, cursor: 'pointer', fontSize: 13,
        }}>
          Change password
        </button>
      </div>
      <div style={{ display: 'flex', gap: 8, margin: '0 16px', alignItems: 'center' }}>
        <button onClick={logout} style={{
          flex: 1, padding: '10px', background: 'rgba(255,255,255,.15)',
          color: 'var(--sidebar-text)', border: 'none', borderRadius: 6, cursor: 'pointer',
        }}>
          Sign out
        </button>
        <ThemeToggle theme={theme} toggle={toggle} />
      </div>
      {pwOpen && <ChangePasswordModal onClose={() => setPwOpen(false)} />}
    </aside>
  )
}

// The phone/tablet header: hamburger, the institution mark beside the product name,
// and the theme toggle on the right. The sidebar itself lives in the drawer on these
// screens, so everything reachable from a desktop is reachable from a phone.
function MobileTopBar({ brand, role, theme, toggle, onMenu }: {
  brand: Branding | null
  role: Role
  theme: Theme
  toggle: () => void
  onMenu: () => void
}) {
  const name = brand?.name || 'QAAT'
  return (
    <div style={{
      position: 'sticky', top: 0, zIndex: 30, display: 'flex', alignItems: 'center', gap: 10,
      padding: '8px 12px', background: 'var(--sidebar)', color: 'var(--sidebar-text)',
    }}>
      <button onClick={onMenu} aria-label="Open menu" style={{
        background: 'rgba(255,255,255,.15)', border: 'none', borderRadius: 6, cursor: 'pointer',
        color: 'var(--sidebar-text)', width: 40, height: 40, fontSize: 18, flexShrink: 0,
      }}>☰</button>
      <div style={{ minWidth: 0 }}>
        <strong style={{ fontSize: 15, display: 'block', lineHeight: 1.2 }}>KIU QAAT</strong>
        <span style={{ fontSize: 11, opacity: .8, display: 'block', marginTop: 2 }}>
          {name}
          {role ? ` · ${role.replace('_', ' ')}` : ''}
        </span>
      </div>
      <div style={{ marginLeft: 'auto' }}>
        <ThemeToggle theme={theme} toggle={toggle} />
      </div>
    </div>
  )
}

// Self-service password change — works for any signed-in role (POST verifies the
// current password and updates the hash everywhere).
function ChangePasswordModal({ onClose }: { onClose: () => void }) {
  const [cur, setCur] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  async function submit() {
    if (next.length < 8) { setErr('New password must be at least 8 characters.'); return }
    if (next !== confirm) { setErr('New passwords do not match.'); return }
    setBusy(true); setErr(null)
    try {
      await api.post('/api/v1/auth/change-password', { current_password: cur, new_password: next })
      setDone(true)
    } catch (e) { setErr(e instanceof Error ? e.message : 'Failed to change password') }
    finally { setBusy(false) }
  }

  return createPortal(
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.5)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 9999 }}>
      <div onClick={e => e.stopPropagation()} style={{ background: 'var(--surface,#fff)', color: 'var(--text,#0f172a)', borderRadius: 12, padding: 24, width: 360 }}>
        <h3 style={{ margin: '0 0 16px' }}>Change password</h3>
        {done ? (
          <>
            <p style={{ color: '#16a34a' }}>✓ Password changed. Use it next time you sign in.</p>
            <button onClick={onClose} style={pwBtn}>Close</button>
          </>
        ) : (
          <>
            {err && <div style={{ background: '#fef2f2', color: '#b91c1c', padding: '8px 12px', borderRadius: 6, marginBottom: 12, fontSize: 13 }}>{err}</div>}
            <PasswordInput placeholder="Current password" value={cur} onChange={e => setCur(e.target.value)} style={pwInp} />
            <PasswordInput placeholder="New password (min 8)" value={next} onChange={e => setNext(e.target.value)} style={pwInp} />
            <PasswordInput placeholder="Confirm new password" value={confirm} onChange={e => setConfirm(e.target.value)} style={pwInp} />
            <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
              <button onClick={submit} disabled={busy || !cur || !next} style={pwBtn}>{busy ? 'Saving…' : 'Update password'}</button>
              <button onClick={onClose} style={{ ...pwBtn, background: 'transparent', color: 'var(--text,#334155)', border: '1px solid var(--border,#e2e8f0)' }}>Cancel</button>
            </div>
          </>
        )}
      </div>
    </div>,
    document.body,
  )
}
const pwInp: React.CSSProperties = { width: '100%', padding: '10px', borderRadius: 6, border: '1px solid var(--border,#e2e8f0)', fontSize: 14, marginBottom: 10, boxSizing: 'border-box', background: 'var(--surface,#fff)', color: 'var(--text,#0f172a)' }
const pwBtn: React.CSSProperties = { padding: '10px 16px', background: 'var(--brand)', color: '#fff', border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 600, fontSize: 13 }

// A back-button shown on every sub-page so the user can always go back to the
// previous page. Hidden on the base role route (e.g. /vc, /qa/reports, /admin).
function GoBack({ navigate: nav, location: loc }: { navigate: ReturnType<typeof useNavigate>; location: ReturnType<typeof useLocation> }) {
  const baseRoutes = ['/vc', '/dqa', '/qa/reports', '/admin', '/hod', '/dean', '/qa-dept', '/qa-school', '/tlc']
  const isBase = baseRoutes.some(b => loc.pathname === b || loc.pathname === b + '/')
  if (isBase) return null
  return (
    <button onClick={() => nav(-1)} style={{
      background: 'none', border: 'none', color: 'var(--brand, #2563eb)', cursor: 'pointer',
      fontSize: 13, fontWeight: 600, padding: 0, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 4,
    }}>
      ← Back
    </button>
  )
}
