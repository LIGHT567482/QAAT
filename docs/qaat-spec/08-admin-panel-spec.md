# 08 — Admin Panel Spec (Filament)

QAAT replaces the customized Django admin with a **Laravel + Filament** admin panel. This document defines the resources, metrics, and behaviors required for parity with the current admin (`backend/upanel/admin_setup.py`, `backend/templates/admin/`, registered models) plus recommended improvements.

**Current admin capabilities being replaced:**

- Branded dashboard with stat cards (users by role, verification %, attendance counters, top collections, recent users).
- Quick-nav shortcuts (Dashboard, Server Health, Users, Registrations, Sessions, Check-ins, Notices, All documents, Email tokens, API health).
- Server health page (psutil CPU/mem/disk/network/processes with severity rollup).
- Model admins: `User`, `EmailVerificationToken`, `StudentRegistration`, `PushDevice`, `ApiDocument` (with pretty-JSON preview + smart summary).
- Bulk action: mark selected users' email as verified.
- Staff-only access (`is_staff` gate).

---

## 1. Access control

- Filament users authenticate via Laravel session (separate from mobile bearer tokens).
- Map Filament login to the shared `users` table (§3 of [03 — Database](03-database.md)): require `is_staff=true` (or a new `filament_user=true` flag) + active.
- Roles within Filament: `super_admin` (everything), `qa_operator` (users, attendance read, notices), `support` (read-only dashboards). Map from `users.role` where sensible.
- No self-registration in Filament; accounts created via existing staff-hub flows or seed.

---

## 2. Dashboard (parity + improvements)

Port of `get_dashboard_context()` (`backend/upanel/admin_setup.py`).

### 2.1 Metrics (widgets)

| Metric | Definition (current) | Notes |
|---|---|---|
| Total users | `users` count | |
| Students / Lecturers / QA / Administrators | count by role | Administrators = administrator + kiu_admin |
| Staff total | users with `staff_number` | |
| Verified students | students with `email_verified` | |
| Pending email verifications | students not verified | |
| Verify % | verified / total students | |
| Inactive users | `is_active=false` | |
| Registrations claimed | `student_registrations` with `user_id` | |
| New users (week / day) | created_at windows | |
| Push devices | `push_devices` count | |
| Pending verification tokens | unused, unexpired | |
| Expired verification tokens | expired | |
| Attendance sessions / lists / records | table counts | current counts ApiDocument collections; QAAT counts typed tables |
| Notices | count | |
| Documents total | **currently mislabeled** — counts `accounts/users`; QAAT: actual total documents + per-collection counts (fix, see [15](15-gaps-and-fixes.md) §4) | |
| Top collections | top 8 by row count | |

### 2.2 Widgets / layout

- Stat cards grid (current `templates/admin/upanel_dashboard.html`).
- Alerts: unverified students threshold, expired tokens.
- Top collections table.
- Recent users table (10).
- Quick-nav panel (current `includes/sysadmin_nav.html`): Dashboard, Server Health, Users, Registrations, Sessions (filter `attendance/sessions`), Check-ins (`attendance/records`), Notices, All documents, Email tokens, API health.

Filament implementation: custom dashboard page with `Stat` widgets, `Table` widgets, and a `Widget` grid; or multiple simple widgets.

---

## 3. Resources

### 3.1 `UserResource`

- **List:** searchable (name, email, reg no, staff no); filters: role, verified, active, staff; sortable created_at.
- **Columns:** full_name, email, role badge, registration_number, staff_number, email_verified toggle, is_active, is_staff, created_at.
- **Form:** all fields from `users` table; role select; password set (hashed, never shown).
- **Actions:** "Mark verified" (bulk — parity with Django bulk action), "Force logout" (revoke tokens), "Send password reset", "Delete" (soft-delete recommended).
- **Global search:** enabled.

### 3.2 `StudentRegistrationResource`

- List claims: registration_number, user (relation), email_verified_at_link, created_at.
- Actions: attach to user manually (resolve disputed claims), release claim.

### 3.3 `EmailVerificationTokenResource` (read-mostly)

- List: user, expires_at (valid/expired badge), used_at, created_at.
- Actions: revoke (mark used), copy link (admin-only diagnostic — do not email from list view by default).

### 3.4 `PasswordResetTokenResource` (optional; current has admin for verification tokens only)

- Same shape; read-only recommended.

### 3.5 `PushDeviceResource`

- List: user, platform, player_id (truncated), tags (JSON preview), updated_at.
- Actions: delete device (user's phone reinstall), bulk delete by platform.

### 3.6 `AttendanceListResource` / typed tables or Documents browser

If typed tables (recommended): standard Filament resource over `attendance_lists` with filters (lecturer, date range, status), relation manager for sessions.

If schemaless `documents` table: reuse pattern from current `ApiDocumentAdmin` (`backend/documents/admin.py`):

- Search collection + doc_id; filters by collection and updated_at range.
- Inline pretty-JSON preview of `data`.
- Smart `summary_preview`: fullName / title / sessionCode / email / status / registrationNumber (port the current preview logic).

Provide a **Documents browser** resource for any collection (including `notices`, `campus/presence`, `attendance/*`) as the universal fallback — this is the highest-value admin tool for support.

### 3.7 `AttendanceSessionResource`

- List: session_code, list_id, status badge, start/end, created_by, remote_learning, location_metadata_pending, roll_discarded.
- Filters: status, date, remote vs on-campus.
- Actions: view linked records (relation), force-close session, view join code (for support).

### 3.8 `AttendanceRecordResource`

- List: session_id, student_id, present badge, verified badge, course, timestamp, device_id.
- Filters: present/verified, session, list, date.
- Actions: toggle present (writes `present=false/true` — must enqueue missed-session notice when flipping to absent, same as API hook).

### 3.9 `CheckInAttemptResource` (support tool)

- List: status badge, student, session, rejection_reason, awaiting_session, captured_at.
- Filters: status, rejection_reason, awaiting_session, date.
- Actions: reprocess pending attempt (enqueue sweep job).

### 3.10 `NoticeResource`

- List: title, kind, audience, scheduled_for, send_push toggle, push_sent_at, expires_at.
- Form: full notice fields; preview push copy (port `push_copy_for_notice` defaults).
- Actions: "Send push now" (enqueue), duplicate, expire.

### 3.11 `CampusPresenceResource`

- List: admin_uid (resolve name), event_type, local_date_key, captured_at, coords.
- Filters: date range, admin, event_type.

### 3.12 `CampusGeofenceResource` (singleton settings page)

- Edit form for geofence centre/radius/label; audit fields updated_by/at.

### 3.13 `JobOutboxResource` (QAAT-specific observability)

- List pending/failed jobs (topic, attempts, run_at, error).
- Actions: retry now, mark done, view payload.

---

## 4. Server health page

Port of `backend/upanel/server_monitor.py` + `admin/server_health.html` + `/admin/server-health/api/`.

Metrics (via gopsutil in a small Go sidecar, or psutil in a Python/Filament route):

- CPU: per-core, freq, load average.
- Memory + swap.
- Disk: filtered partitions (hide docker/overlay), disk I/O.
- Network I/O + interfaces (hide container bridges).
- Top 10 processes by CPU/RAM.
- Boot/uptime.

Severity rollup `get_health_status()`: healthy | warning | critical with thresholds (CPU >75/90%, mem >80/90%, disk >80/90%). Auto-refresh via polling the JSON endpoint.

Filament: dedicated page (not a resource) linked from dashboard + nav; staff-only middleware.

---

## 5. Branding & UX

- App name: **QAAT Admin** (replaces "U-Panel System Admin").
- Logo, favicon, primary color (current green `#177245` retained unless brand change).
- Footer: DB vendor, cache backend, email backend, TZ, debug warning (port `base_site.html` system footer).
- Login page branded (port `login.html`).
- Dark mode optional (Filament built-in).

---

## 6. Audit log (recommended QAAT addition)

Filament `activity_log` plugin (or custom `audit_logs` table) recording:

- Admin user, action (create/update/delete/login), model, changes, timestamp, IP.

Critical for FERPA-like accountability on attendance record edits and user role changes.

---

## 7. Seed & demo

Port Django seeds to Filament seeders / artisan commands:

- QA demo user: `KIU-0001` / email `kiu0001@staff.qaat.local`, role `qa_staff`, `is_staff=true`, verified.
- Demo attendance list: `demo-attendance-list` with courses, year/sem, lecturer sign code.

Expose as `php artisan qaat:seed-demo` (or management command equivalent).

---

## 8. API health shortcut

Dashboard link → `GET /api/health/` in new tab (or embedded JSON view). Shows `{status, service, push_delivery_configured}`.

---

## 9. Filament implementation checklist

- [ ] Laravel 11 + Filament 3 project `qaat-admin` (or monorepo `admin/`).
- [ ] Shared DB with Go API (read/write same Postgres).
- [ ] Auth bridge from `users` table; `is_staff` gate.
- [ ] Resources: User, StudentRegistration, EmailVerificationToken, PushDevice, AttendanceList, AttendanceSession, AttendanceRecord, CheckInAttempt, Notice, CampusPresence, CampusGeofence, JobOutbox, Documents browser.
- [ ] Dashboard widgets with parity metrics + fixed documents_total.
- [ ] Server health page + JSON endpoint.
- [ ] Bulk "mark verified" action.
- [ ] Record present-toggle enqueues missed-session notice outbox (parity with API hook).
- [ ] Branding QAAT; audit log plugin.
- [ ] Seed commands.
- [ ] Docker image in compose topology ([13](13-deployment-ops.md)).
