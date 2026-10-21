# 01 — System Overview

## 1. What QAAT is

QAAT is a **campus attendance and academic-operations system** built for Kampala International University (KIU). It replaces manual paper registers with:

- **Digital class lists** — lecturers (or QA staff) create lists per lesson (course, program, year, semester, room, date).
- **Geofenced check-in sessions** — a lecturer opens a timed session with a join code and a GPS geofence; students check in from inside the classroom area.
- **Roll tracking** — every session produces a three-state roll (Present / Absent / Pending) per student; attendance percentages feed eligibility decisions.
- **Staff campus presence** — KIU administrators/QA check in and out of campus under time-based policies (on-time, early departure, overwork).
- **Notices & push** — targeted notifications (all users, one class list, one student, KIU admins, one lecturer) via OneSignal, including automated "you missed class" notices.
- **Reporting** — consolidated rolls, lecturer-teaching rolls, staff-presence rolls, CSV/PDF export.

The system is **offline-first** on mobile: students in rooms with poor connectivity queue check-ins locally and sync when back online.

---

## 2. Users and roles

Five roles exist in the current system (`backend/accounts/models.py`, `lib/core/auth/user_role.dart`):

| Role | Key | Who | Primary powers |
|---|---|---|---|
| Student | `student` | Enrolled students (default role at registration) | Sign into class lists, check in to sessions, view own attendance history, receive notices |
| Lecturer | `lecturer` | Teaching staff | Create/edit class lists, start/end sessions, view rolls for own lists, create targeted notices |
| QA staff | `qa_staff` | Quality-assurance staff | All lecturer powers + oversight of all lists/sessions, start sessions for overdue classes, staff management, reports |
| Administrator | `administrator` | System administrators | Full operations: users, notices, reports, dashboards, staff administration |
| KIU admin | `kiu_admin` | Senior KIU administrators | Everything administrator can do + campus presence check-in/out + KIU-admin-only notices |

**Derived flags** used throughout:

- `is_administrator` = administrator ∨ qa_staff ∨ kiu_admin (`backend/accounts/models.py` properties)
- `hasStaffOperationalAccess` = qaStaff ∨ admin (client)
- `hasLecturerAttendanceAccess` = lecturer ∨ kiuAdmin (client)

**Important current limitation** (fixed in QAAT, see [15 — Gaps](15-gaps-and-fixes.md)): role checks exist only in the mobile client and Django admin. The document router API itself has **no per-collection authorization** — any authenticated user can read/write any collection. QAAT must enforce role-based authorization server-side.

---

## 3. Core domains

```
┌────────────┐     ┌──────────────────────────────────────────┐
│  accounts  │────▶│ users, admins, lecturers,                │
│            │     │ student-registrations, staff-numbers,    │
│            │     │ push devices, email/reset tokens         │
└────────────┘     └──────────────────────────────────────────┘
       │
       ▼
┌────────────┐     ┌──────────────────────────────────────────┐
│ attendance │────▶│ lists ─▶ sessions ─▶ check-in-attempts   │
│            │     │            │                              │
│            │     │            └─▶ records (present/absent)  │
│            │     │ students (roster), sign-ins (enrollment) │
└────────────┘     └──────────────────────────────────────────┘
       │
       ├──────────▶ campus presence (staff check-in/out, geofence)
       │
       └──────────▶ notices (manual + automated missed-session)
                            │
                            └─▶ OneSignal push
```

### 3.1 Attendance domain (the heart of the system)

Relationship chain:

1. **Attendance list** (`attendance/lists/{id}`) — one lesson: title, room, lecturer, date, program, courses, year, semester, status.
2. **Attendance session** (`attendance/sessions/{id}`) — a live check-in window on a list: join code, start/end time, GPS centre + radius, status (`active` → `closed`), flags (`remoteLearning`, `locationMetadataPending`, `rollDiscarded`).
3. **Check-in attempt** (`attendance/check-in-attempts/{id}`) — raw student submission with GPS + device id; server adjudicates to `accepted` or `rejected`.
4. **Attendance record** (`attendance/records/{sessionId}_{studentId}`) — the authoritative outcome: `present` (bool), `verified` (bool), timestamp, coordinates.

Supporting collections:

- `attendance/students` — per-list roster entries (3-digit codes, initials, course).
- `attendance/sign-ins` — a student "signing into" (enrolling on) a list; required before check-in in the intended flow.
- `attendance/health` — misc meta documents (campus geofence at `campus/geofence`, connectivity ping, staff counters).

Full attendance logic, including code generation and every "what if" scenario, is specified in [06 — Attendance Module](06-attendance-module.md).

### 3.2 Accounts domain

- `accounts/users/{uid}` — mirrored profile for every Django user.
- `accounts/admins/{uid}`, `accounts/lecturers/{uid}` — role projections.
- `accounts/student-registrations/{REG}` — registration-number claims.
- `accounts/staff-numbers/{STAFF}` — staff-number allocations (`KIU-0001` style).

### 3.3 Notices domain

- `notices/{id}` — title, body, kind, audience, targets, scheduling, push state.
- Automated `missedSession` notices are created server-side whenever a record is marked absent.

### 3.4 Campus domain

- `campus/presence` — staff/KIU-admin check-in/check-out events.
- Campus geofence document (`attendance/health` → `campus/geofence`).

### 3.5 Reports domain

Client-side computation over lists × sessions × records:

- Per-list roll (students × sessions grid with percentage).
- Lecturer teaching roll.
- Admin campus-presence roll.
- CSV / PDF / plain-text export.

---

## 4. Environments and deployment shape (current)

- **API:** Django 6 + DRF (token auth) served by Gunicorn behind Nginx.
- **Workers:** Celery worker + Celery beat (Redis broker).
- **Database:** PostgreSQL 16 in production; SQLite fallback for dev.
- **Cache/broker:** Redis 7.
- **Push:** OneSignal.
- **Email:** Mailjet (SMTP fallback).
- **Errors:** Sentry.
- **Hosts (current):** `kiu.orion13.us` / `api.kiu.orion13.us` (Cloudflare-fronted Contabo VPS).

QAAT keeps the same operational shape but splits the API into Go (hot path) + Python (workers) + Filament/Laravel (admin). See [02 — Architecture](02-architecture.md) and [13 — Deployment](13-deployment-ops.md).

---

## 5. Rename: django-U-Panel / U-Panel → QAAT

This section is the summary. The full ordered checklist lives in [14 — Rename & Migration Playbook](14-rename-migration-playbook.md).

### 5.1 What is renamed

| Item | Current | QAAT target |
|---|---|---|
| Product name | U-Panel | **QAAT** |
| Repo name (local + GitHub) | django-U-Panel | **QAAT** (or `qaat`) |
| Django project package | `upanel` | `qaat_api` (or per-service name in Go/Python split) |
| Flutter package | `u_panel` | `qaat` |
| Android applicationId | `com.u_panel` | `com.kaat.campus` (example — pick one and keep stable) |
| Android deep-link scheme | `upanel://` | `qaat://` |
| iOS bundle id | (from `ios/`) | same as applicationId |
| iOS URL scheme | `upanel` | `qaat` |
| OneSignal tags prefix | unchanged (`stu_`, `lec_`, `list_`, `kiu_admins`) | unchanged (no data migration needed) |
| Brand strings | "U-Panel" in headers, emails, admin site | "QAAT" |
| Email from-name | "U-Panel" | "QAAT" |
| Admin site header | "U-Panel System Admin" | "QAAT Admin" |
| Public API URL | `https://kiu.orion13.us` | new domain of choice (e.g., `https://qaat.kiu.ac.ug`) |
| Sentry project | upanel | qaat |
| Celery app name | `upanel` | per-service |
| Hive box name | `u_panel_attendance_queues` | `qaat_attendance_queues` (with read-fallback migration) |

### 5.2 What must NOT change (data compatibility)

- **Document collection names** (`attendance/lists`, `attendance/sessions`, …) — mobile clients and server hooks address these strings directly.
- **Document field names** (`sessionCode`, `studentId`, `deviceId`, `present`, `verified`, …) — changing them breaks offline queues and server adjudication.
- **OneSignal tag grammar** — `stu_<uid>`, `lec_<uid>`, `list_<listId>`, `kiu_admins`, `all_notices`.
- **Record id scheme** `{sessionId}_{studentId}` and missed-notice id `missed_{sessionId}_{studentId}`.
- **Session join-code format** `A12B` (plus legacy acceptance of `###`, `####`, `L###`).

### 5.3 Rename strategy

Two valid strategies (detailed in [14](14-rename-migration-playbook.md)):

1. **Fresh QAAT build** (recommended) — new repo, port behavior per this spec, run QAAT alongside U-Panel, cut over mobile apps when feature parity is verified. No live-data migration required if the rebuild starts empty; optional ETL of `ApiDocument` rows into the new schema later.
2. **In-place rename + refactor** — rename identifiers in the current repo first, then incrementally extract Go/Python/Filament services. Higher risk; only sensible if U-Panel production must keep running unchanged during the transition.

This spec set assumes **strategy 1** unless stated otherwise.

---

## 6. Non-goals for QAAT v1

- Timesheet / employee working-hours tracking (the system is class-session based, not HR timesheets).
- Server-side generation of join codes (remains client-generated; see [06](06-attendance-module.md) — a future enhancement is server-minted codes).
- Native (non-Flutter) mobile apps — Flutter remains the single mobile codebase.
- Real-time collaborative editing of class lists (single-writer assumed; conflicts resolved by last-write-wins on the document store).

---

## 7. Glossary

| Term | Meaning |
|---|---|
| **List** | One scheduled lesson (course × program × date) that students sign into. |
| **Session** | A live, timed check-in window opened by a lecturer on a list. |
| **Join code** | Short code (`A12B`) a student types to find the active session. |
| **Attempt** | A student's raw check-in submission (before server adjudication). |
| **Record** | Authoritative attendance outcome for one student in one session. |
| **Roll** | Grid of students × sessions with Present/Absent/Pending labels and percentages. |
| **Grace** | 7-day window after a session during which unverified check-ins may still resolve before being marked absent. |
| **Geofence** | GPS centre + radius defining the allowed check-in area for a session. |
| **Campus presence** | Staff/KIU-admin GPS attendance (check-in/out) against a campus-wide geofence. |
| **Queue** | Persistent local (Hive) store of offline work awaiting sync. |
