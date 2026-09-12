import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { AuthProvider } from './contexts/AuthContext'
import { RoleLayout } from './layouts/RoleLayout'
import Login from './pages/Login'
import Unauthorized from './pages/Unauthorized'
import WelcomeToast from './components/WelcomeToast'

import VCOverview from './pages/vc/VCOverview'
import VCLecturerWorkload from './pages/vc/VCLecturerWorkload'
import DQAHome from './pages/dqa/DQAHome'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import DQAEligibility from './pages/dqa/DQAEligibility'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import DQACourseHealth from './pages/dqa/DQACourseHealth'
import DQAPunctuality from './pages/dqa/DQAPunctuality'
import DQAPatrolCoverage from './pages/dqa/DQAPatrolCoverage'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import DQAUnitAttendance from './pages/dqa/DQAUnitAttendance'
import DQAReportsHub from './pages/dqa/DQAReportsHub'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import QADeviceReset from './pages/qa/QADeviceReset'
import QAPresenceClaims from './pages/qa/QAPresenceClaims'
// Retained for restore; unreachable while student attendance taking is suspended.
// import QAManualCorrection from './pages/qa/QAManualCorrection'
// The single placeholder every deferred route answers with. See DeferredToV2.tsx for why
// the routes survive rather than being deleted.
import DeferredToV2 from './pages/shared/DeferredToV2'
import QACoordinatorHealth from './pages/qa/QACoordinatorHealth'
import AdminHome from './pages/admin/AdminTenants'
import AdminSettings from './pages/admin/AdminSettings'
import AdminUsers from './pages/admin/AdminUsers'
import AdminCourses from './pages/admin/AdminCourses'
import AdminCourseUnits from './pages/admin/AdminCourseUnits'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import AdminStudents from './pages/admin/AdminStudents'
import AdminRooms from './pages/admin/AdminRooms'
import AdminSchools from './pages/admin/AdminSchools'
import OrgLecturers from './pages/OrgLecturers'
import AdminLecturers from './pages/admin/AdminLecturers'
import AdminLecturerAssignments from './pages/admin/AdminLecturerAssignments'
import AdminLecturerAttendance from './pages/admin/AdminLecturerAttendance'
import AdminCoordinators from './pages/admin/AdminCoordinators'
import AdminEmployees from './pages/admin/AdminEmployees'
import AdminEmployeeAttendance from './pages/admin/AdminEmployeeAttendance'
import AdminReports from './pages/admin/AdminReports'
import DashLecturerAttendance from './pages/shared/DashLecturerAttendance'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import QAStudentAttendance from './pages/qa/QAStudentAttendance'
import QAReports from './pages/qa/QAReports'
import { QAOrgLecturers, QAOrgDepartments, QAOrgReports } from './pages/qa/QAOrgDashboard'
import Timetable from './pages/shared/Timetable'
import FreeRooms from './pages/shared/FreeRooms'
import LecturerAssignments from './pages/shared/LecturerAssignments'
import EmployeeAttendance from './pages/shared/EmployeeAttendance'
import LecturerPortal from './pages/LecturerPortal'
import OrgOverview from './pages/shared/OrgOverview'
// DEFERRED TO V2 — the page is retained and still compiles; only its route is suspended.
// import AtRisk from './pages/shared/AtRisk'
import AdminAudit from './pages/admin/AdminAudit'
import OrgDepartments from './pages/shared/OrgDepartments'
import Inbox from './pages/shared/Inbox'
// Re-enabled with the student phone check-in (§5.7 U-Panel migration): the attempts
// log is the evidence behind every refused check-in from geo-checkin/offline-batch.
import CheckinAttempts from './pages/shared/CheckinAttempts'
import PendingSync from './pages/shared/PendingSync'

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <WelcomeToast />
        <Routes>
          <Route path="/login"        element={<Login />} />
          <Route path="/unauthorized" element={<Unauthorized />} />
          {/* Public, passwordless, read-only lecturer attendance portal. */}
          <Route path="/lecturer-portal" element={<LecturerPortal />} />

          {/* ── VC ─────────────────────────────────────────────────────── */}
          <Route element={<RoleLayout allowedRoles={['VC']} />}>
            <Route path="/vc"                     element={<VCOverview />} />
            <Route path="/vc/lecturer-workload"   element={<VCLecturerWorkload />} />
            <Route path="/vc/lecturer-attendance" element={<DashLecturerAttendance />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/vc/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/vc/student-attendance"  element={<QAStudentAttendance />} /> */}
                        {/* U-PANEL INTEGRATION: DEFERRED TO V2 — original route kept below for restore. */}
                        <Route path="/vc/upanel-attendance" element={<DeferredToV2 module="upanel" />} />
                        {/* <Route path="/vc/upanel-attendance"   element={<Navigate to="/vc/student-attendance" replace />} /> */}
            <Route path="/vc/checkin-attempts"    element={<CheckinAttempts />} />
            <Route path="/vc/pending-sync"        element={<PendingSync />} />
            {/* Read-only: the VC does not build the schedule, but every figure on the pages
                above is measured against it, and having to ask someone for it is friction on
                exactly the question the dashboard exists to answer. */}
            <Route path="/vc/timetable"           element={<Timetable readOnly />} />
            <Route path="/vc/free-rooms" element={<FreeRooms />} />
            <Route path="/vc/messages"            element={<Inbox />} />
            <Route path="/vc/alerts"              element={<Navigate to="/vc/messages" replace />} />
            <Route path="/vc/employee-attendance" element={<EmployeeAttendance />} />
          </Route>

          {/* ── DQA Director ───────────────────────────────────────────── */}
          <Route element={<RoleLayout allowedRoles={['DQA_DIRECTOR']} />}>
            <Route path="/dqa"              element={<DQAHome />} />
            <Route path="/dqa/thresholds"   element={<Navigate to="/dqa" replace />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dqa/eligibility" element={<DeferredToV2 />} />
            {/* <Route path="/dqa/eligibility"  element={<DQAEligibility />} /> */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dqa/course-health" element={<DeferredToV2 />} />
            {/* <Route path="/dqa/course-health" element={<DQACourseHealth />} /> */}
            <Route path="/dqa/trends"       element={<Navigate to="/dqa" replace />} />
            <Route path="/dqa/punctuality"  element={<DQAPunctuality />} />
            <Route path="/dqa/lecturer-attendance" element={<DashLecturerAttendance />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dqa/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/dqa/student-attendance"  element={<QAStudentAttendance />} /> */}
                        {/* U-PANEL INTEGRATION: DEFERRED TO V2 — original route kept below for restore. */}
                        <Route path="/dqa/upanel-attendance" element={<DeferredToV2 module="upanel" />} />
                        {/* <Route path="/dqa/upanel-attendance"   element={<Navigate to="/dqa/student-attendance" replace />} /> */}
            <Route path="/dqa/checkin-attempts"    element={<CheckinAttempts />} />
            <Route path="/dqa/pending-sync"        element={<PendingSync />} />
            <Route path="/dqa/qa-reports"          element={<QAReports />} />
            {/* The gateway already authorises these roles to read the timetable; there
                simply was no page, so oversight could not see the week it was judging. */}
            <Route path="/dqa/timetable"           element={<Timetable readOnly />} />
            <Route path="/dqa/free-rooms" element={<FreeRooms />} />
            <Route path="/dqa/alerts"              element={<Navigate to="/dqa/messages" replace />} />
            <Route path="/dqa/employee-attendance" element={<EmployeeAttendance />} />
            <Route path="/dqa/messages"            element={<Inbox />} />
            <Route path="/dqa/presence-claims"     element={<QAPresenceClaims />} />
            <Route path="/dqa/monitor-messages"  element={<Navigate to="/dqa/messages" replace />} />
            {/* The at-risk watchlist, institution-wide. Every other oversight role already had
                this — HOD, dean, both QA reps and the admin — and the DQA director, who SETS the
                threshold those students are measured against, was the one role that could not see
                who was failing it. */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dqa/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/dqa/at-risk"             element={<AtRisk />} /> */}
            {/* One row per department, across every college, so the directorate can compare units
                against each other instead of reading a separate report per school.

                OrgDepartments and NOT OrgOverview, deliberately. The overview is a single-org-unit
                landing page — it says "your department" / "your college" and is bounded by the
                caller's own — whereas this directorate is bounded by nothing, and the institution
                rollup it would show is already the top of DQAHome. The departments handler already
                has an unbounded path and DQA_DIRECTOR is already in orgDashRoles, so this needs no
                backend change: the director simply gets every department rather than one school's. */}
            <Route path="/dqa/org"                 element={<OrgDepartments />} />
            {/* How much of the timetable the QA round actually reached. Was /dqa/patrol-coverage
                until the feature was renamed to QA Monitor Coverage; the old path still resolves so
                a bookmark or a link in an old email does not dead-end at the login page. */}
            <Route path="/dqa/monitor-coverage"    element={<DQAPatrolCoverage />} />
            <Route path="/dqa/patrol-coverage"     element={<Navigate to="/dqa/monitor-coverage" replace />} />
            {/* The two attendance records for the same unit, in one row each. */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dqa/unit-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/dqa/unit-attendance"     element={<DQAUnitAttendance />} /> */}
            {/* The map of everything above — reports named by the question they answer. */}
            <Route path="/dqa/reports"             element={<DQAReportsHub />} />
          </Route>

          {/* ── QA Officer ─────────────────────────────────────────────── */}
          <Route element={<RoleLayout allowedRoles={['QA_OFFICER']} />}>
            <Route path="/qa/reports"           element={<QAReports />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa/device-reset" element={<DeferredToV2 />} />
            {/* <Route path="/qa/device-reset"      element={<QADeviceReset />} /> */}
            {/* STUDENT ATTENDANCE TAKING: SUSPENDED. The form is retained and still
                compiles; it is unreachable while student attendance is suspended, and
                the backend route it posts to is commented out too. */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa/correction" element={<DeferredToV2 />} />
            {/* <Route path="/qa/correction"        element={<AttendanceSuspended />} /> */}
            {/* <Route path="/qa/correction"        element={<QAManualCorrection />} /> */}
            <Route path="/qa/coordinator-health" element={<QACoordinatorHealth />} />
            <Route path="/qa/presence-claims"    element={<QAPresenceClaims />} />
            <Route path="/qa/monitor-messages" element={<Navigate to="/qa/messages" replace />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/qa/student-attendance"  element={<QAStudentAttendance />} /> */}
                        {/* U-PANEL INTEGRATION: DEFERRED TO V2 — original route kept below for restore. */}
                        <Route path="/qa/upanel-attendance" element={<DeferredToV2 module="upanel" />} />
                        {/* <Route path="/qa/upanel-attendance"   element={<Navigate to="/qa/student-attendance" replace />} /> */}
            <Route path="/qa/checkin-attempts"    element={<CheckinAttempts />} />
            <Route path="/qa/pending-sync"        element={<PendingSync />} />
            <Route path="/qa/lecturer-attendance" element={<DashLecturerAttendance />} />
            <Route path="/qa/timetable"           element={<Timetable />} />
            <Route path="/qa/free-rooms" element={<FreeRooms />} />
            <Route path="/qa/employee-attendance" element={<EmployeeAttendance />} />
            <Route path="/qa/messages"            element={<Inbox />} />
          </Route>

          {/* ── Tenant Admin (own institution only) ────────────────────── */}
          <Route element={<RoleLayout allowedRoles={['ADMIN']} />}>
            <Route path="/admin"                                      element={<AdminHome />} />
            <Route path="/admin/settings"                             element={<AdminSettings />} />
            <Route path="/admin/users"              element={<AdminUsers />} />
            <Route path="/admin/schools"            element={<AdminSchools />} />
            <Route path="/admin/courses"            element={<AdminCourses />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/admin/students" element={<DeferredToV2 />} />
            {/* <Route path="/admin/students"           element={<AdminStudents />} /> */}
            <Route path="/admin/timetable"                            element={<Timetable />} />
            <Route path="/admin/free-rooms" element={<FreeRooms />} />
            <Route path="/admin/rooms"              element={<AdminRooms />} />
            {/* /venues is the old path for the same page — kept so existing links resolve. */}
            <Route path="/admin/venues"             element={<AdminRooms />} />
            <Route path="/admin/courses/:courseId/units"              element={<AdminCourseUnits />} />
            <Route path="/admin/coordinators"          element={<AdminCoordinators />} />
            <Route path="/admin/lecturers"              element={<AdminLecturers />} />
            <Route path="/admin/lecturer-assignments"  element={<AdminLecturerAssignments />} />
            <Route path="/admin/lecturer-attendance"   element={<AdminLecturerAttendance />} />
            <Route path="/admin/employees"             element={<AdminEmployees />} />
            <Route path="/admin/employee-attendance"   element={<AdminEmployeeAttendance />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/admin/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/admin/student-attendance"    element={<QAStudentAttendance />} /> */}
                        {/* U-PANEL INTEGRATION: DEFERRED TO V2 — original route kept below for restore. */}
                        <Route path="/admin/upanel-attendance" element={<DeferredToV2 module="upanel" />} />
                        {/* <Route path="/admin/upanel-attendance"   element={<Navigate to="/admin/student-attendance" replace />} /> */}
            <Route path="/admin/checkin-attempts"    element={<CheckinAttempts />} />
            <Route path="/admin/pending-sync"        element={<PendingSync />} />
            <Route path="/admin/reports"                                 element={<AdminReports />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/admin/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/admin/at-risk"                                 element={<AtRisk />} /> */}
            <Route path="/admin/audit"                                   element={<AdminAudit />} />
            <Route path="/admin/messages"                                element={<Inbox />} />
          </Route>

          {/* A LECTURER HAS NO WEB CONSOLE. Their whole job — starting a lecture at the
              coordinator's gate, answering a monitor's finding, running a distance class, writing
              to a coordinator — happens on the phone, in the room, often with no signal. The
              read-only /lecturer-portal above still exists for looking attendance up from a
              browser. Login sends a lecturer to the app by name rather than to a route that would
              404 and read as a failed sign-in. */}

          {/* ── HOD (own department) / Dean (own school) ─────────────────
              Both landed on a bare lecturer list with no sense of whether their unit was
              working. They now open on the KPI overview, with the lecturer list, the
              at-risk watchlist, the timetable and their inbox alongside it. Every page is
              scoped server-side by the unit on their own account. */}
          <Route element={<RoleLayout allowedRoles={['HOD']} />}>
            <Route path="/hod"           element={<OrgOverview level="hod" />} />
            <Route path="/hod/lecturers" element={<OrgLecturers level="hod" />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/hod/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/hod/at-risk"   element={<AtRisk />} /> */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/hod/attendance" element={<DeferredToV2 />} />
            {/* <Route path="/hod/attendance" element={<QAStudentAttendance />} /> */}
            {/* Assignment moved here from the admin console: staffing a department's
                units is the head of department's job, and the server scopes it to
                their own department rather than trusting anything this page sends. */}
            <Route path="/hod/assignments" element={<LecturerAssignments />} />
            <Route path="/hod/timetable" element={<Timetable readOnly />} />
            <Route path="/hod/messages"  element={<Inbox />} />
          </Route>
          <Route element={<RoleLayout allowedRoles={['DEAN']} />}>
            <Route path="/dean"            element={<OrgOverview level="dean" />} />
            {/* The management layer a dean is accountable THROUGH — skipped entirely before. */}
            <Route path="/dean/departments" element={<OrgDepartments />} />
            <Route path="/dean/lecturers"  element={<OrgLecturers level="dean" />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dean/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/dean/at-risk"   element={<AtRisk />} /> */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/dean/attendance" element={<DeferredToV2 />} />
            {/* <Route path="/dean/attendance" element={<QAStudentAttendance />} /> */}
            <Route path="/dean/timetable" element={<Timetable readOnly />} />
            <Route path="/dean/messages"  element={<Inbox />} />
          </Route>

          {/* ── TLC: Teaching & Learning Centre ─────────────────────────
              The timetable's owner. A deliberately narrow console — the timetable
              and the rooms it refers to — because that is the whole of the role.
              It used to be the IT administrator's job by default, which was an
              accident of who had the button rather than whose work it is. */}
          <Route element={<RoleLayout allowedRoles={['TLC']} />}>
            <Route path="/tlc"       element={<Timetable />} />
            <Route path="/tlc/rooms" element={<AdminRooms />} />
            <Route path="/tlc/free-rooms" element={<FreeRooms />} />
          </Route>

          {/* ── QA reps: department rep / school handler ────────────────── */}
          <Route element={<RoleLayout allowedRoles={['QA_DEPT_REP']} />}>
            <Route path="/qa-dept"          element={<OrgOverview level="qa-dept" />} />
            <Route path="/qa-dept/lecturers" element={<QAOrgLecturers />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa-dept/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/qa-dept/at-risk"  element={<AtRisk />} /> */}
            <Route path="/qa-dept/report"   element={<QAOrgReports />} />
            {/* The two attendance records, both bounded to this rep's own department by the
                gateway (lecturerLogScope / qaFiltersScoped) rather than by anything on screen. */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa-dept/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/qa-dept/student-attendance"  element={<QAStudentAttendance />} /> */}
            <Route path="/qa-dept/lecturer-attendance" element={<DashLecturerAttendance />} />
            <Route path="/qa-dept/timetable" element={<Timetable readOnly />} />
            <Route path="/qa-dept/messages" element={<Inbox />} />
          </Route>
          <Route element={<RoleLayout allowedRoles={['QA_SCHOOL_HANDLER']} />}>
            <Route path="/qa-school"           element={<OrgOverview level="qa-school" />} />
            <Route path="/qa-school/departments" element={<OrgDepartments />} />
            <Route path="/qa-school/qa-departments" element={<QAOrgDepartments />} />
            <Route path="/qa-school/lecturers" element={<QAOrgLecturers />} />
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa-school/at-risk" element={<DeferredToV2 />} />
            {/* <Route path="/qa-school/at-risk"   element={<AtRisk />} /> */}
            <Route path="/qa-school/reports"   element={<QAOrgReports />} />
            {/* Same two records, bounded to this handler's own college — including the extra
                colleges carried in user_schools, which the scope resolver already folds in. */}
            {/* STUDENT MODULE: DEFERRED TO V2 — original route kept below for restore. */}
            <Route path="/qa-school/student-attendance" element={<DeferredToV2 />} />
            {/* <Route path="/qa-school/student-attendance"  element={<QAStudentAttendance />} /> */}
            <Route path="/qa-school/lecturer-attendance" element={<DashLecturerAttendance />} />
            <Route path="/qa-school/timetable" element={<Timetable readOnly />} />
            <Route path="/qa-school/messages"  element={<Inbox />} />
            <Route path="/qa-school/presence-claims" element={<QAPresenceClaims />} />
          </Route>

          <Route path="*" element={<Navigate to="/login" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
