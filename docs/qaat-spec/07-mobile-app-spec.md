# 07 — Mobile App Spec (Android & iOS)

The Flutter client is the primary student/lecturer interface. This document defines **every screen and feature** that must exist in the QAAT mobile apps (Android + iOS; web parity noted where relevant) so nothing is lost in the rebuild.

**Current source:** `lib/` (~69.5k Dart LOC), `android/`, `ios/`. Package `u_panel` → QAAT (`pubspec.yaml`).

**Architecture notes:** plain Flutter + `ChangeNotifier` singletons (no Provider/Riverpod/Bloc required in QAAT — keep or upgrade, but preserve repository + in-memory `AttendanceStore` pattern). State: `StatefulWidget` + `setState` predominantly; `AuthRepository`, `AppConnectivity`, `StudentLocationPriming` are ChangeNotifiers.

---

## 1. Bootstrap & platforms

### 1.1 Startup (`lib/main.dart`)

1. Sentry wrap (`runAppWithSentry`, `core/monitoring/app_sentry.dart`; DSN via `--dart-define=SENTRY_DSN`).
2. OneSignal SDK init (`core/push/onesignal_service.dart`).
3. Web fast-boot path: `runApp` immediately; async storage+API with 5–8s timeouts.
4. Native path: Hive queues init (corrupt-storage recovery + sanitize) → `ApiClient.ensureLoaded` + `ApiAuth.restoreSession` → background notification tasks → `AppConnectivity` + `PushController` → `AuthRepository.loadInitialSession`.
5. Sign-out triggers `AppSessionReset` + route pop-to-root.

### 1.2 Root routing (`core/navigation/auth_gate.dart`)

```
signed-out                    → AuthScreen
email unverified              → EmailVerificationScreen
KIU admin onboarding pending  → KiuAdminOnboardingScreen
else                          → AppShell
```

### 1.3 Platform capabilities

| Capability | Android | iOS |
|---|---|---|
| Location permission | FINE/COARSE (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`) | `NSLocationWhenInUseUsageDescription` |
| Notifications | `POST_NOTIFICATIONS` | entitlement + permission prompt |
| Background | `RECEIVE_BOOT_COMPLETED`, `WAKE_LOCK`, Workmanager | fetch, processing, remote-notification background modes |
| Deep links | App Links `https://<domain>/app`; custom scheme `qaat://open` | Universal Links + URL scheme `qaat` |
| Storage | Hive (no special perm) | Hive |
| Package / bundle | `com.u_panel` → **QAAT applicationId** | same bundle id |

QAAT must request runtime permissions contextually (location priming on app open/resume for students who will check in; notification permission after first sign-in or before session start for lecturers).

---

## 2. Roles & navigation

`core/auth/user_role.dart`: `student`, `lecturer`, `qaStaff`, `admin`, `kiuAdmin`.

Nav sections (`app_shell.dart::_navSectionsForRole`):

| Role | Sections |
|---|---|
| admin / qaStaff | Dashboard, Attendance, Notices, Reports, Settings |
| lecturer / kiuAdmin | Dashboard (Home), Attendance, Notices, Settings |
| student | Attendance, Notices, Settings (Profile) |

- Mobile bottom bar omits Reports for staff (reachable via drawer/hub); desktop (≥ breakpoint) uses sidebar with admin extras (Campus check-in area, Lecturer lessons, staff & accounts).
- Unseen-notices badge on Notices tab (counts visible+live not seen for user key = uid or `reg:` key; marks seen on enter).
- Offline banner when connectivity probes fail (2 failed API pings → offline, `core/connectivity/app_connectivity.dart`).

---

## 3. Feature inventory by area

### 3.1 Auth (`lib/features/auth/`)

| Screen / feature | Role | Notes |
|---|---|---|
| Login / Register tabs (`auth_screen.dart`) | all | KIU email/reg-number validation; OTP/2FA sub-screen (`_LoginVerificationScreen`); offline banner; debug API-base label |
| Email verification (`email_verification_screen.dart`) | all | verify student/staff mailbox; resend |
| Forgot password (`forgot_password_screen.dart`) | all | password-reset link |
| Staff self-registration (`kiu_staff_register_screen.dart`) | staff path | |
| KIU admin onboarding (`kiu_admin_onboarding_screen.dart`) | kiu_admin | post-verify "Are you a KIU administrator?" |
| Student portal WebView (`portal/student_portal_screen.dart`) | student | in-app browser to student portal |

### 3.2 Attendance — lecturer/admin (`lib/features/attendance/`)

- Hub / day / program / list drill-down: `AttendanceDayProgramsScreen`, `AttendanceProgramListsScreen`, `AttendanceListSessionsScreen`, hierarchy helpers (`attendance_list_hierarchy.dart`).
- Create/edit/delete list: `CreateAttendanceListScreen`, `EditAttendanceListScreen` (title, room, date, program, courses, year, sem, lecturer sign code, assigned lecturer for QA).
- **Start session** (`StartSessionScreen`): radius `[100,200,500,1500]`m default 1500; durations `[1,10,15,20,25]`min default 15; remote-learning toggle; location resolving panel; double-start guards.
- **Session code display** (`_SessionCodeDisplay`): live countdown, copy, publish-to-server, manual end (confirm), auto-end on expiry + roll finalize.
- **Session check-ins** (`SessionCheckInsScreen`): live roll with pending-sync markers.
- **QA extras**: `qa_overdue_attendance_screen.dart` (no attendance 1:30 after lesson; QA can start session), `qa_program_session_ui.dart`, `today_attendance_lists_screen.dart` + filter.
- Schedule helpers: `attendance_schedule_utils.dart`, `assigned_lecturer_field.dart`, feedback toasts (`attendance_top_feedback.dart`).

### 3.3 Attendance — student check-in

- Sign-in content (`_SignInContent` in `attendance_screen.dart`): registration number (locked when student-scoped) + session code.
- Unknown-code confirm dialog (`unknown_session_code_confirm.dart`): save code (queue ≤7 days) or re-enter.
- Geofence + time local verify (`check_in_validation.dart`).
- Progress pipeline (`student_check_in_progress_screen.dart`): staged progress, 20s busy countdown, result + Done/Back; online/offline outcome cards (green/amber/offline).
- Auto check-in from push (`data/session_code_auto_check_in.dart`, `session_code_push_utils.dart`): 20s debounce.
- Student history: `student_class_attendance_detail_screen.dart` (per-session detail from Profile; "Missed — session ended before you joined…").

### 3.4 Offline & queues (`lib/features/attendance/data/` + `core/offline/` + `core/storage/`)

Hive box (current `u_panel_attendance_queues`; QAAT: `qaat_attendance_queues` with read-fallback migration):

| Key | Contents |
|---|---|
| `pending_attendance_check_ins` | check-in entries (see [12](12-offline-and-sync.md)) |
| `pending_attendance_session_codes` | typed codes awaiting validation/claim |
| `pending_attendance_session_sync_summary` | sync bookkeeping |
| `pending_attendance_session_creates` | lecturer offline session creates |
| `pending_attendance_list_creates` | lecturer offline list creates |
| `pending_campus_presence` | staff campus events |
| `cached_campus_geofence_v1` | cached campus geofence |

Queue writers: `pending_check_in_queue.dart`, `pending_session_code_queue.dart` / `_claim_upload` / `_sync.dart`, `pending_session_create_queue.dart` / `_sync.dart`, `pending_list_create_queue.dart` / `_sync.dart`, `pending_retention.dart` (7-day), `pending_attendance_evidence.dart`, `offline_capture_trust.dart`.

Drain orchestrator (`attendance_offline_sync.dart`): pending session creates → session-code validation → GPS check-ins → list creates → campus presence → `loadAll`; separate full vs urgent locks (urgent = check-ins only, never blocked); `drainSessionValidationFirst` on reconnect; `drainUrgentUploadsOnly` for background/blur; 7-day purge. Coordinator: `core/offline/pending_offline_coordinator.dart` (5s tick, 150ms debounce, 50s background timeout, lifecycle-aware).

UI: `pending_sessions_screen.dart` (local-first paint, 8s poll, reconcile timeline), `offline_queue_location_screen.png` → `offline_queue_location_screen.dart` (fullscreen GPS while queueing).

Remote watches: `attendance_remote_list_watch.dart`, `attendance_remote_record_watch.dart`, `attendance_remote_sign_in_watch.dart`, `attendance_rtd_record_watch.dart`; purge `attendance_list_purge.dart`.

Device anti-proxy: `core/device/device_identity.dart` (stable install id), `device_session_usage_store.dart` (shared-phone proxy block after sign-out).

### 3.5 Campus presence (`lib/features/campus_presence/`)

- Policy (`campus_presence_policy.dart`): on-time ≤ **08:30**, early departure < **17:00**, overwork > **17:30**.
- Geofence: `campus_geofence_validation.dart` (min radius 1.5 km for QA; options 100/200/500/1500 m), `update_campus_location_screen.dart` (set campus area), cached in Hive.
- Actions: check-in/check-out (`campus_presence_check_actions.dart` + `campus_presence_check_progress.dart`); queue `pending_campus_presence_queue.dart` / `_sync.dart`; repo `campus_presence_repository.dart`.
- Screens: KIU-admin dashboard integration, `admin_campus_presence_card.dart`, `campus_presence_log_screen.dart`, `admin_campus_absent_list_screen.dart`, `campus_presence_staff_detail_screen.dart`, `kiu_admin_check_in_records_screen.dart`, status widgets, `kiu_admin_ui.dart`.
- Models: `CampusGeofence`, `CampusPresenceEvent`, `AdminCampusDayStatus`, dashboard summary, roster.

### 3.6 Reports & roll (`lib/features/reports/`)

- Hub (`reports_screen.dart`): KIU administrators card (arrivals/departures/late/overwork by date, weekly counts), Lecturers card (teaching dates/classes/rooms/durations), Attendance rolls hierarchy (day → program → year → sem → list), QA stats, refresh timestamp, print-all; lecturer variant = "My class lists".
- Hierarchy: `reports_attendance_hierarchy.dart`.
- Rolls: `attendance_list_roll_screen.dart` (per-student % × session grid, Present/Pending/Absent colors, **CSV export** with BOM + clipboard + web download, **print** plain-text), `attendance_list_roll.dart`, `reports_admin_presence_roll_screen.dart`, `reports_lecturer_teaching_screen.dart`.
- Export/print: `reports_csv_data.dart`, `reports_roll_pdf.dart`, `reports_pdf_text.dart`, `report_pdf_generation_dialog.dart`, `report_print.dart` (+`_web`/`_stub`), `report_download.dart`, `report_file_save.dart` (+`_io`/`_web`/`_stub`), period dialogs, `admin_presence_roll_export.dart`, `lecturer_teaching_roll_export.dart`.
- Roll logic detail: [11 — Reports & Roll](11-reports-and-roll.md).

### 3.7 Notices & push (`lib/features/notices/`, `core/push/`, `core/notifications/`)

- `notices_screen.dart`: list (60s auto-refresh), create entry, push toggle, copy session code, unseen badge.
- `create_notice_screen.dart` + `notice_create_flow.dart`: audience = all users / class list (lecturer: assigned/created lists only) / single student (server-generated missed) / KIU admins; title, body, "Valid for" schedule.
- `notices_repository.dart`: `NoticeRecord`, effective/live windows, broadcast-vs-per-list push eligibility, session-code broadcast suppressed for remote learning, per-user seen keys, **7-day disk cache** (`notices_disk_cache.dart`), audience filtering.
- Push: `push_controller.dart` (OneSignal mobile; web/desktop notice polling `desktop_notice_watch.dart`), `push_tag_builder.dart` (tags must match server grammar), `onesignal_service.dart`, `onesignal_integration_verification.dart`.
- Local notifications: lesson-start reminders (lecturer), QA overdue reminders at +1:30 (`attendance_lesson_notification_scheduler.dart`), pending-offline 24h reminder (`pending_offline_notification_scheduler.dart`), Workmanager periodic maintenance, reboot re-apply, stable ids (`notification_ids.dart`).

### 3.8 Dashboards (`lib/features/dashboard/`)

- Admin/QA (`dashboard_screen.dart`): stats, live sessions (`live_sessions_list_screen.dart`), recent notices, today's lists, campus presence summary, lesson insights.
- Lecturer (`lecturer_dashboard_screen.dart`): teaching-focused home.
- KIU admin (`kiu_admin_dashboard_screen.dart`): campus check-in/check-out hero actions, policy hints (8:30/5:00/5:30), campus area card, records, presence hero.

### 3.9 Lesson insights (`lib/features/lesson_insights/`)

Computed from `AttendanceStore`: `lesson_insights_service.dart`, dashboard section, lecturer lessons + period lessons + session detail, QA lecturers-on-day + lesson activity, period filter.

### 3.10 Settings & account (`lib/features/settings/`)

- Shared cards (`settings_shared.dart`): Update profile, Change password, Student Portal, Privacy Policy, Delete account, About (Kampala International University).
- Role variants: `settings_screen.dart` (admin/QA/student), `lecturer_settings_screen.dart`, `qa_staff_settings_screen.dart`, `kiu_admin_settings_screen.dart`.
- Account screens: `update_profile_screen.dart` (name, reg number, optional admin role), `change_password_screen.dart`, `delete_account_screen.dart`, `privacy_policy_screen.dart`.
- Staff admin hub (`staff_admin_hub_screen.dart`): Lecturers / Administrators / QA staff management; `register_staff_screen.dart` (QA vs lecturer, auto/manual `KIU-####`, default password), `register_administrator_screen.dart`, `register_kiu_administrator_screen.dart`, `staff_credentials_screen.dart`, list screens, `staff_password_reset_screen.dart`, `lecturers_qa_admin_screen.dart`.

### 3.11 Location & connectivity core (`lib/core/location/`, `core/connectivity/`, `core/device/`)

- `location_permission.dart`: GPS-on + permission gate (web uses browser Geolocation); `GpsAcquireResult`; last-known reuse (5-min check-in window); `forceFresh` + high accuracy for ≤100m radii.
- `student_location_priming.dart`: prime permission+GPS on open/resume.
- `location_resolving_panel.dart`: inline GPS status.
- `gps_location_settings.dart`: platform-tuned accuracy/timeouts (web/iOS slow first fix).
- `app_connectivity.dart`: connectivity_plus + API ping (2 failed probes → offline banner); `online_first_persist.dart`.

---

## 4. Acceptance criteria (feature-parity checklist for QAAT apps)

### 4.1 Student

- [ ] Register with KIU email / reg number; complete email verification.
- [ ] Sign into a class list (choose course) — online and offline.
- [ ] Enter session code → local geofence+time validation → online check-in with staged progress.
- [ ] Offline check-in: local record + queue; auto-sync on reconnect; 7-day grace then absent.
- [ ] Unknown code dialog (save-for-later / retry).
- [ ] Duplicate check-in friendly message.
- [ ] Rejection messages for all 6 server reasons (see [06](06-attendance-module.md) §6).
- [ ] GPS disabled → clear recovery UI ("Turn on location").
- [ ] Remote-learning session check-in without geofence.
- [ ] Push-triggered auto check-in from session code.
- [ ] View own attendance history / class detail ("Missed — session ended before you joined…").
- [ ] Notices list + unseen badge + push receipt.
- [ ] Profile: update name, change password, delete account, privacy policy, student portal link.
- [ ] Campus geofence cached for location context (read-only for students).

### 4.2 Lecturer

- [ ] Create/edit/delete class lists (courses, year/sem, room, date, sign code).
- [ ] Start session (radius/duration/remote options; GPS required on-campus).
- [ ] Double-start guards; live countdown; copy code; share via notice.
- [ ] End & save roll (confirm dialog explaining 7-day pending); auto-end on expiry.
- [ ] End without saving (discard) with full data purge.
- [ ] View session check-ins / live roll with pending markers.
- [ ] Mark students absent (writes `present:false` → triggers missed-session notice).
- [ ] Lesson reminders (local notifications).
- [ ] Offline: create list/session queued; drain on reconnect.
- [ ] My class lists (assigned only) in reports.

### 4.3 QA staff

- [ ] All lecturer powers across all lists.
- [ ] Overdue attendance screen (classes with no attendance 1h30m after lesson); start session on behalf.
- [ ] Today's attendance lists + filters.
- [ ] Staff management hub (create lecturers/admins/QA; staff numbers; credentials display; password reset).
- [ ] Reports hub with QA stats; refresh timestamps.
- [ ] Notices including `qaStartAttendance` kind.

### 4.4 Administrator / KIU admin

- [ ] Dashboard: user stats, live sessions, recent notices, today's lists, campus presence summary, lesson insights.
- [ ] Campus check-in/check-out (KIU admin) with policy thresholds and geofence (≥1.5km QA min).
- [ ] Campus presence log, absent list, staff detail, check-in records screens.
- [ ] Update campus location (geofence admin).
- [ ] KIU-admin notices audience.
- [ ] Reports: admin presence roll, lecturer teaching roll; CSV/PDF export.
- [ ] Staff & accounts management (same hub as QA + administrator grants).

### 4.5 Cross-cutting

- [ ] Offline banner; pending-work badge (`countPendingWork`).
- [ ] OneSignal tags registered correctly per role (`stu_`, `lec_`, `list_`, `kiu_admins`, `all_notices`).
- [ ] Deep links: `qaat://open/email-verified`, `https://<domain>/app`.
- [ ] Sentry crash reporting; structured enough breadcrumbs for check-in failures.
- [ ] Workmanager background maintenance; reboot re-applies notification tasks.
- [ ] Web parity for core flows (fast-boot, CSV download, print dialogs, notice polling instead of OneSignal).

---

## 5. API surface used by the app

Base config: `lib/core/api/api_config.dart` (`--dart-define=API_URL` / `UPANEL_API_BASE_URL`; web runtime `window.upanelApiBaseUrl`). Collections constants: `lib/core/api/api_collections.dart`.

Auth: `api_auth.dart` (token restore, logout). Data: Firebase-style wrappers `ApiStore`, `ApiAuth`, `ApiUser` over the document router (see [04 — Backend API](04-backend-api.md)).

QAAT Flutter port keeps the same REST contract; update only base URL + auth scheme if JWT chosen.

---

## 6. Testing carried over

Flutter tests to port/keep green:

- `test/check_in_validation_test.dart` — geofence math, time bounds, remote/pending skips.
- `test/discarded_session_roll_test.dart` — discard excludes from stats.
- `test/attendance_list_scope_test.dart` — list-scoped trust.
- `test/staff_attendance_cache_policy_test.dart` — cache behavior.
- `test/attendance_role_routing_test.dart` — role → nav sections.
- `test/consolidated_roll_student_names_test.dart` — name/merge rendering.
- `test/campus_geofence_validation_test.dart` — campus geofence rules.

Add QAAT-specific: rename migration tests (old Hive box → new), auth scheme tests, server-authorization 403 handling UX.
