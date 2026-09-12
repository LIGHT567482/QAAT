# U-Panel attendance + admin-dashboard migration plan

Status: **DRAFT — pending sign-off. No code changed yet.**
Date: 2026-09-11

## 1. Goal

Adopt the attendance model and admin-dashboard feature set of the
`michaellubega/django-U-Panel` platform into QAAT, remove QAAT's current
attendance tracking flow, and keep **QAAT's student check-in flow** (students
type their registration number on the in-room hub) as the only way a student
registers presence.

U-Panel references the codebase at
`/tmp/opencode/django-U-Panel` (Flutter client + Django backend). All
"U-Panel" file references below are to that checkout.

## 2. Decisions locked (user's answers)

| # | Question | Decision |
|---|----------|----------|
| A | Student entry | **REVERSED (2026-09-12).** Students check in from THEIR OWN PHONES (U-Panel flow): the lecturer opens a register, reads out the code, and each student types code + reg-no while their phone reports its own coordinates. Phone GPS/geofence, one-device-one-person and per-phone offline queues are IN. The in-room hub/hotspot semantics are retired (student-path endpoints `/api/v1/attendance/geo-checkin`, `ping`, `offline-batch` and the attempts log are re-enabled). |
| B | Lecturer session model | **Lecturer opens the session** (U-Panel style): lecturers create/own class lists and open sessions with a join code. This replaces coordinator-driven session opening. |
| C | QA patrol | Keep the QA patrol walk-in feature (`lecturer_patrol_logs`). U-Panel QA screens (overdue escalation, lesson insights) are added on top. |
| D | Time gates & room code | Keep QAAT's daily session window, `session_active_days`, HOTP rotating room code, and T+120/T+180 policies as guardrails, running under the U-Panel list/session model. |
| E | Offline architecture | Port U-Panel's queue model wholesale: attempt/claim/`awaitingSession` queues plus server-side sweeps, re-implemented in Go. |
| F | Process | Plan first; implement only after sign-off of this document. |
| G | **Flutter app roles (2026-09-12)** | The `coordinator-flutter` app hosts, in ONE app with the SAME unified login, the roles **LECTURER, STUDENT, ADMINISTRATOR(S)** — each lands on their own dashboard/features. COORDINATOR is added later once its roles are defined. |
| H | **Admin presence (2026-09-12)** | Administrators check in/out as in U-Panel (`campus_presence`): geofenced check-in/out with presence roll — §5.10 is IN SCOPE (was open question 1). |
| I | **Admin dashboards stay** | The web `admin-dashboards` app is KEPT and gains the missing U-Panel features (§5.1–5.10). It must run perfectly on a phone: responsive layout (drawer sidebar) + PWA-installable. |

Note: decision A's reversal means §2's "U-Panel student phone features … are dropped" statement is obsolete.

## 3. Reference recap

### 3.1 U-Panel model (what we are porting)

U-Panel stores live attendance as JSON docs in a Firestore-shaped table
(`documents.ApiDocument`), in six collections with **strictly separate roles**:

| Collection | Meaning | Written by |
|---|---|---|
| `attendance/lists` | class roster list (program/day/year/sem, courses, `who_taught`/`lecturerUid`, room) | lecturer creates |
| `attendance/sessions` | live session: join code, geofence (lat/lng/radius), start/end, `status=active`, `finalized` | lecturer opens |
| `attendance/check-in-attempts` | raw evidence: studentId, code, GPS, deviceId, `capturedAt`, `status` pending→accepted/rejected + `rejectionReason` | student submits |
| `attendance/records` | final verdict, idempotent key `{sessionId}_{studentId}`, `present`+`verified` | server engine only |
| `attendance/sign-ins` | manual lecturer roster marks | lecturer |
| `attendance/students` | student profile mirror | server sync |

Validation pipeline (`backend/documents/services/check_in.py` `maybe_process_check_in`):
1. only `status` empty/`pending` processed,
2. link to session by `sessionCode` (`__iexact`, `status=active`); if absent and
   `awaitingSession`/code present, **keep pending for later sweep**; else reject `session code not found`,
3. require `studentId`,
4. **time window**: `capturedAt` within `[start-2min, end]` (after `end` only while
   `status=active`); if device/server clock skew > 5 min, trust server receipt time,
5. **one-device-one-person**: same `deviceId` already `present` for another student → reject,
6. **geofence**: haversine ≤ `radius + 25m buffer + uncertainty(min(0.5·accuracy, 75m))`;
   `remoteLearning`/`locationMetadataPending` bypass; zero-centre bypass,
7. upsert `attendance/records` row (idempotent) + mark attempt `accepted`.

Server tasks: `sweep_awaiting_session_claims` (every 30 s, links pre-session
claims), `process_check_in_doc` (async after POST), `finalize_expired_sessions`.
Retention: 7 days for offline queues.

### 3.2 QAAT current state (what we are replacing / reusing)

Already built and **shipped**:

- **Migrations 100–105** already implement much of the U-Panel data model:
  - `upanel_attendance` mirror table (100),
  - org-resolution columns `unit_id/department/school/resolved_via/unresolved` (101),
  - `sessions.latitude/longitude/radius_meters(default 1500)/gps_accuracy_meters/session_code` (102),
  - `attendance_logs.captured_at/received_at/captured_offline/client_queue_id/latitude/longitude/distance_meters/device_id` (102, 103),
  - `checkin_attempts` table (104) — session_id nullable, outcome `PRESENT|DUPLICATE|REJECTED`, reason, distance, device_id, `captured_offline`,
  - `sessions.finalized`, `sessions.lecturer_sign_code`, `sessions.lecturer_signed_at`, `students_extended.three_digit_code` (104),
  - `upanel_people_into_registry` (105),
  - who's-who index `ux_sessions_active_code WHERE session_status='ACTIVE'` (102).
- Gateway package `internal/upanel/` (client, store, resolve, people, summary) +
  handler `handlers/upanel_attendance.go`; front-end `pages/admin/UPanelRecords.tsx` and
  `pages/qa/StudentAttendanceRoll.tsx` consume `/api/v1/dashboard/upanel/attendance`.
- Geofence verifier already ported: `backend/api-gateway/internal/checkin/geofence.go` (`VerifyCheckin`).
- **But all of it is parked**: router endpoints are commented out
  (`STUDENT MODULE: DEFERRED TO V2`, ~26 blocks in `internal/router/router.go`),
  routes in `frontend/admin-dashboards/src/App.tsx` mount `DeferredToV2`,
  tabs in `DashLecturerAttendance.tsx`/`EmployeeAttendance.tsx`/
  `AdminLecturerAttendance.tsx` are commented, and
  `internal/upsert`/`RefreshIfEmpty` calls in `org_dashboard.go`,
  `qa_student_attendance.go`, `lecturer_attendance_dashboard.go`, `audit.go` are commented out.
- **Student attendance is suspended server-side**: `backend/sync-receiver/internal/sync/receiver.go:542-552`
  counts but does not write student records ("remove this block to restore").
- Current lecturer flow is **coordinator-driven**: `OpenSession` in
  `handlers/sessions.go` (`session_status_enum`: PENDING_LECTURER/ACTIVE/CLOSED/AUTO_CLOSED),
  seeds `lecturer_attendance_logs`, HOTP room code in `internal/checkin/roomcode.go`,
  policies T+120/T+180 in `internal/policy/policy.go`, session window in
  `handlers/session_window.go`, sweep infra in `scheduled_job_runs` + `jobs/`.
- `attendance_logs` is append-only (no DELETE); corrections via `ENTRY_METHOD=MANUAL_OVERRIDE`.
- Lecturer attendance is recorded **twice by design**: `lecturer_attendance_logs`
  (coordinator START/END contact hours) and `lecturer_patrol_logs` (QA patrol).
  Decision C keeps only the patrol half; contact-hours move to the session record.

## 4. Target architecture

### 4.1 Data model (delta on top of migrations 100–105)

```
attendance_lists (NEW)             -- maps U-Panel attendance/lists
  list_id         UUID PK
  offering_id     UUID NOT NULL  REFERENCES course_offerings (cohort anchor; decision B)
  title           TEXT
  room            TEXT
  lecturer_id     VARCHAR(50)    REFERENCES lecturers
  session_variant TEXT           -- Day | Evening | Weekend (from offering)
  year_label, semester, program  TEXT   -- denormalised from offering + term config
  created_by      UUID           REFERENCES users
  created_at      TIMESTAMPTZ
  UNIQUE (offering_id, year_label, semester, program)

sessions (EXTEND — reuses 102/104 columns)
  + list_id            UUID       REFERENCES attendance_lists   (NEW)
  + opened_by          UUID       REFERENCES users              (NEW; = lecturer, replaces coordinator_id intent)
  + join_code_label    TEXT       -- human caption of the code, for audits

checkin_attempts (EXTEND — reuses 104)
  + awaiting_session   BOOLEAN DEFAULT false     -- U-Panel awaitingSession flag
  + list_id            UUID  (denormalised for lecturer/Qa dashboards)
  + resolved_at        TIMESTAMPTZ

attendance_logs (KEEP as the ledger record — maps attendance/records)
  -- all 102/103 columns already present; add nothing.
  -- idempotency already: checkin_attempts solves PRESENT/DUPLICATE via outcome.

session_sign_ins (NEW)            -- maps attendance/sign-ins (manual lecturer roster marks)
  sign_in_id UUID PK, session_id FK, student_id, list_id, marked_by, marked_at
  UNIQUE (session_id, student_id)

-- user an attractive home for lecturers' own teaching record:
lecturer_attendance_logs (REDEFINE SEMANTICS, SAME TABLE/COLUMNS)
  -- written now by the lecturer's own session OPEN/CLOSE instead of coordinator gate seeding.
  -- contact_hours = session duration. Patrol logs remain untouched (decision C).
```

Mapping notes:
- **list** ≈ one `course_offerings` row + its term context at a given day/time
  (migrations 24/41/65 logic; session `offering_id` stamp). Seeding strategy from
  `timetable_slots` → `offering_unit_schedules` → attendance_lists, preserving the
  migration-065 cohort rule.
- **attempts** stay even when REJECTED/null session (migration 104 rationale).
- **records** = `attendance_logs` rows; write path is U-Panel-engine shaped
  (validation in a shared Go package), NOT the current raw capture path.

### 4.2 Shared validation engine (Go port of `check_in.py`)

New package `backend/api-gateway/internal/attendanceverifier` (or
`backend/internal/attendance/` shared by gateway + sync-receiver + session-manager):

```
Verify(attempt) -> Decision{Accepted|Duplicate|Rejected(reason), present, verified}
  - link session by code (upper, ACTIVE)          (ux_sessions_active_code)
  - studentId present and not already accepted IDEMPOTENT (PRESENT)
  - within window [start-2min, end] with clock-skew rule
  - one-device-one-person (device_id on attendance logs/records of same session)  [server-side, decision A only applies to *phone* flows; hub typing stays per-person by hub]
  - geofence via existing internal/checkin/geofence.go (reuse constants 25/75)
```

Behaviour contract copied from `check_in.py`:
- raw claims accepted → upsert `attendance_logs` (entry_method `QR_SCAN` label per AGENTS, or a new `HUB_ENTRY` value) + mark attempt `PRESENT`,
- rejected → attempt `REJECTED` + reason (no attendance_logs row),
- unresolved code with `awaitingSession`/code present → attempt `QUEUED` and left for the sweep job,
- re-submission of accepted student/session → attempt `DUPLICATE`, no new log row.

### 4.3 Sweeps (Go port of Celery beats)

Reuse `scheduled_job_runs` infra (`db/migrations/073_...`, `backend/api-gateway/internal/jobs/`):
- `attendance.sweep_awaiting_session_claims` — every 30 s; link claims whose code now matches an ACTIVE session; then run Verify.
- `attendance.finalize_expired_sessions` — close past-`end` sessions; set `finalized`.
- session-window and T+120/T+180 remain enforced at open/check-in time (decision D), as today.

### 4.4 Service-by-service changes

| Service | Change |
|---|---|
| `api-gateway` | Un-defer U-Panel module. New routes (see 5.2). Verify-against live hub check-ins (queue path lives in sync-receiver; live path can reuse same package). Re-point org/QA/lecturer dashboards to new tables. Keep HOTP + window + policy. |
| `sync-receiver` | Replace the SUSPENDED block (receiver.go:542) with: write `checkin_attempts` (always), plus `attendance_logs` only when Verify accepts; resolve `offering_id` (migration 065 rule); stamp lecturer attendance from the session's open (not the old coordinator gate). |
| `session-manager` | Lecturer session open/close (decision B); lecturer sign-in stake (`lecturer_sign_code`/`lecturer_signed_at`, migration 104); hand the CLAIM path for offline codes (awaitingSession). |
| `notification-service` | Notices with class-list audiences (push); QA overdue reminders at T+1h30 (decision B+U-Panel constant); optional missed-session notice (U-Panel `missed_session_notice.py`). |

### 4.5 What is eliminated / retired

- The coordinator-driven `OpenSession`/`CloseSession` flow as the *source* of lecturer
  attendance; coordinator END fingerprints and `daily-code:%` contact-hour markers.
- The "resume coordinator perpetual session" hub logic.
- The SUSPENDED student block + all `STUDENT MODULE: DEFERRED TO V2` dead routes;
  replaced by the real student hub flow + verifier.
- Deferred U-Panel read-only mirror workflows: `upanel_attendance` becomes the
  import *backup* (migration 100 rationale: survive an U-Panel outage) rather than
  the primary; primary reads move to the new tables.
- U-Panel's PR machinery that doesn't fit: phone GPS check-in, phone device-lock,
  student phone codes (decision A).

**Kept** (guardrails, decisions C/D): HOTP room code, session window +
`session_active_days`, T+120/T+180 policy, patrol logs + patroller flow,
append-only `attendance_logs`, RLS + `qaat_app`, sync-receiver chunked upload.

## 5. Admin dashboard delta (features to build in admin-dashboards)

Gap list from U-Panel inventory (`lib/features/...` references for the source):

| # | Screen (U-Panel source) | QAAT build |
|---|---|---|
| 1 | Today's roll hub weekday→program→list, present/absent filter (`today_attendance_lists_screen.dart`) | `/qa` + `/admin` route; reuse `pages/qa/StudentAttendanceRoll.tsx` row machinery |
| 2 | QA overdue — lists where lecturer hasn't opened within 1h30; QA can open (`qa_overdue_attendance_screen.dart`, `attendance_schedule_utils.dart`) | new page + action calling lecturer-open handler |
| 3 | QA lesson insights day/week/month (`qa_lesson_activity_screen.dart`) | new page; counts from sessions sessions in `lecturer_attendance_logs`/sessions rolled-up |
| 4 | Live sessions list (`live_sessions_list_screen.dart`) | new page over ACTIVE sessions |
| 5 | Pending/offline sync screen (`PendingSessionsScreen`) | **DONE (2026-09-12).** `GET /api/v1/attendance/pending` (handlers/checkin_pending.go) + `/pending-sync` page for VC/DQA/QA/ADMIN (pages/shared/PendingSync.tsx), reading `checkin_attempts WHERE awaiting_session OR captured_offline` |
| 6 | List management create/edit, program/day/year/sem, assign lecturer (`attendance_screen.dart` list/start/session screens) | new admin sections; maps to `attendance_lists` + offender selectors |
| 7 | Session check-ins detail incl. failed attempts + distances (`SessionCheckInsScreen`) | new page over `checkin_attempts`; rebuild `UPanelRecords`-style filters for attempts |
| 8 | Notices with audience (all/class-list/student/kiuAdmins) (`notices_repository.dart`) | extend existing app_notifications + recipient targeting |
| 9 | Reports: attendance roll, lecturer teaching roll, admin-presence roll (`reports_*.dart`, client PDF) | implement in QAAT's server-side `report_exports.go` (xlsx/csv/pdf inherit role guards) |
| 10 | (Optional/flag) campus check-in/out presence for admins (`campus_presence/`) | NEW schema `admin_presence_logs` + presence-roll report — **open question §9** |

**Analytics layer (2026-09-12).** Every oversight dashboard now carries the shared
`OverviewAnalytics` (weekly lecturing + student-attendance trend, teached/unevidenced outcome pie,
per-department student-attendance bars, employee time-accuracy stack) — mounted on DQA, VC, Admin,
QA-Officer, HOD, Dean and both QA-rep landing pages. `GET /api/v1/dashboard/dqa/trends` (DQATrends,
embedded in `DQAHome`) was re-enabled with the check-in reversal. The student `attendance_pct` trend
series and `by_group` student-attendance card in `components/OverviewAnalytics.tsx` were restored.

**Messages & alerts (2026-09-12).** §5.8 was already most of the way there and the gap was
backend-originated, not UI: in-app alerts (`/api/v1/app-notifications`) and threaded QA messages
(`/api/v1/messages`) ship to every inbox — the admin dashboards' `Inbox`/`Alerts`/`Messages`/
`QAMonitorBriefing` tabs and the Flutter apps' `AlertCard` inboxes both read them, and the READ
routes' `inboxRoles` already includes `STUDENT`. Three behaviours the U-Panel notices app had are
now generated by the gateway itself:

- **Missed-session notice.** When a session closes — by the lecturer (`LecturerCloseSession`), the
  coordinator (`CloseSession`) or the lecturer ending an online class (`EndOnlineClass`) — every
  ACTIVE student in the session's offering who holds a user account but no `attendance_logs` row
  gets a `SESSION_ABSENT` notification (`notify_absent.go`). It fires after the close has committed
  and is best-effort (a failed notice never fails the close), and it is idempotent per student per
  session via `notification_log` (the recipient folds into `subject_key`). U-Panel's
  `missed_session_notice.py` honour is written into the close handlers.
- **Pre-lecture reminders.** At **30, 15 and 5 minutes** before a lecture starts, every enrolled
  student (with an account) is told via the `student_lecture_reminder` job, and the lecturer is
  told via the `lecture_reminder` job — three distinct notifications per audience per lecture,
  each separately claim-per-audience-per-offset via `notification_log`. Both jobs share the
  `remindStudents`/`remindLecturers`→`sendAppNotificationTo` helpers over `timetable_slots`.
- **Patrol verdict notification.** After a QA monitor records whether a lecturer taught or not
  (`lecturer_patrol_logs`, both the timetabled `PatrolSync` round and the `PatrolManualEntry`
  off-timetable path), the lecturer is told the verdict (`verdictMessage`) in their inbox. The
  alert is claim-then-send keyed on `(unit, date, time, offering, verdict)` so a re-tick with
  the same finding is deduplicated, while a corrected verdict — NOT TAUGHT flipped to TAUGHT or
  vice versa — is a fresh notification. The NOT TAUGHT verdict carries the `APPEAL_NOT_TAUGHT`
  reply action (migration 090).

Both land in the student's own dashboard inbox: the Flutter app's student dashboard (and the
web admin dashboards for staff) render them with mark-read and dismiss, so a student who was absent
reads the notice and the reminders on the screen they check.

## 6. Migration & rollback

- New migrations `109..N` (attendance_lists, session_sign_ins, session list_id/
  opened_by, checkin_attempts extensions). All additive.
- Feature-flag re-deferral: keep `DeferredToV2` fallbacks until E2E green.
- Rollback: re-suspend write path (gateway flag), keep import mirror running.

## 7. Phases

Phase 0 — Design sign-off (this doc; resolve §9)
Phase 1 — Data layer: migrations 109+; seed attendance_lists from timetable/offerings (migration 065 cohort rule); tests.
Phase 2 — Engine: `internal/attendanceverifier` + unit tests (golden matrix from check_in.py incl. clock-skew, 25/75 buffers); wire = geofence.go.
Phase 3 — sync-receiver + session-manager: replace suspended block, route claims/sweeps; job infra; RLS/role checks.
Phase 4 — gateway: un-defer U-Panel routes; new list/session/attempt/check-in handlers; org/QA dashboard reads re-pointed; keep HOTP/window/T+120/180.
Phase 5 — admin-dashboards: screens 1–9 per §5.
Phase 6 — coordinator hub: keep reg-no entry; surface lecturer-opened session + codes; confirm offline queue round-trip.
Phase 7 — notification-service: class-list notices, T+1h30 QA reminders, missed-session.
Phase 8 — E2E + load + security (RLS) + pilot; locks AGENTS.md/docs.

Acceptance: students type reg-no on hub against a lecturer-opened session and land
in `attendance_logs` via the verifier; QA patrol unaffected; all §5 dashboards live;
no `STUDENT MODULE: DEFERRED` routes remain.

## 8. Testing

- Engine: unit matrix mirrored from U-Panel + `internal/checkin/geofence_test.go` fixtures.
- Integration: `make test-gateway`/`test-session`/`test-auth`; `tests/security` RLS (qaat_app).
- E2E: extend `tests/e2e` with a lecturer-open → hub-reg-no → record scenario (hub + gateway + receiver).
- Load: k6 for the verifier + sweeps.

## 9. Open questions for sign-off

1. **Admin campus presence** (§5.10): U-Panel has admin check-in/out with geofence + presence-roll report. QAAT already has the office round / employee presence. Port it or treat as out-of-scope?
2. **Hub + lecturer-open coexistence**: with lecturer opens in their own phone app, does the coordinator hub still show a "room code" (HOTP) alongside the lecturer join code, or does the hub display the lecturer's session only? (decision D kept HOTP; needs an explicit rendering rule)
3. **`entry_method` label** for verifier-written rows: new value `HUB_VERIFIED` vs reuse `QR_SCAN` (the AGENTS-noted legacy label). Suggest new enum value kept append-only transparent.
4. **Contact-hours** now computed from lecturer session durations; the `daily-code` / cross-cohort marker rule (receiver.go:484) — keep the same single-credit algorithm pointed at the new source?
5. **Reports** in QAAT are server-side Excel/CSV/PDF; U-Panel's are client-side. Confirm porting content (columns, filters) into `report_exports.go` rather than shipping a Flutter PDF path.