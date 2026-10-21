# QAAT — System Specification

**QAAT** (renamed from **django-U-Panel** / **U-Panel**) is a campus attendance and academic-operations system for Kampala International University (KIU). It manages class attendance lists, geofenced check-in sessions, student roll tracking, staff campus presence, notices/push notifications, and reporting.

This folder is the **complete, self-contained specification** for rebuilding QAAT on a new stack:

| Layer | Technology |
|---|---|
| Admin panel backend | **Filament** (Laravel / PHP) |
| Mobile & web apps | **Dart / Flutter** (Android, iOS, web) |
| Hot-path API | **Go** |
| Async / worker services | **Python** (FastAPI + workers) |
| Databases | **SQLite** (dev) and **PostgreSQL** (production) |

The current implementation being specified is the Django + Flutter monorepo `django-U-Panel`. Every behavior in the current system is documented here so the rebuild loses no functionality.

---

## How to read this spec

Read in this order for first-time onboarding:

1. [01 — System Overview](01-system-overview.md) — what QAAT is, users, domains, rename plan
2. [02 — Architecture](02-architecture.md) — target stack and service split
3. [03 — Database](03-database.md) — data model for both engines
4. [04 — Backend API](04-backend-api.md) — full REST surface
5. [05 — Auth & Roles](05-auth-and-roles.md) — identity and permissions
6. [06 — Attendance Module](06-attendance-module.md) — the core domain (deepest doc)
7. [07 — Mobile App Spec](07-mobile-app-spec.md) — every Android/iOS feature
8. [08 — Admin Panel Spec](08-admin-panel-spec.md) — Filament resources
9. [09 — Notices & Push](09-notices-and-push.md)
10. [10 — Campus Presence](10-campus-presence.md)
11. [11 — Reports & Roll](11-reports-and-roll.md)
12. [12 — Offline & Sync](12-offline-and-sync.md)
13. [13 — Deployment & Ops](13-deployment-ops.md)
14. [14 — Rename & Migration Playbook](14-rename-migration-playbook.md)
15. [15 — Gaps & Fixes](15-gaps-and-fixes.md)

Modules 06–12 can be read independently once 01–05 are understood.

---

## Spec conventions

- **File references** point into the current `django-U-Panel` source tree as `path/to/file.dart:line` or `path/to/file.py:line` so implementers can verify behavior against the reference implementation.
- **"QAAT behavior"** = the behavior to implement in the rebuild (identical to current behavior unless a gap/fix is called out in [15](15-gaps-and-fixes.md)).
- **"U-Panel" / "django-U-Panel"** = the current system. **"QAAT"** = the new system.
- Collections named like `attendance/lists` follow the current schemaless document-store convention; [03](03-database.md) explains how these map to SQLite/Postgres tables in QAAT.

---

## Current-system source map

| Area | Location in current repo |
|---|---|
| Django backend | `backend/` |
| Document store + check-in engine | `backend/documents/` |
| Auth / accounts | `backend/accounts/` |
| Celery tasks | `backend/attendance/tasks.py`, `backend/notices/tasks.py` |
| Flutter app | `lib/` |
| Attendance domain (client) | `lib/features/attendance/` |
| Reports / roll | `lib/features/reports/`, `lib/features/attendance/roll_cell_status.dart` |
| Notices (client) | `lib/features/notices/` |
| Campus presence | `lib/features/campus_presence/` |
| Existing narrative docs | `docs/ATTENDANCE_BLUEPRINT.md`, `docs/ONLINE_CHECK_IN_REPORT.md`, `docs/U_PANEL_ALGORITHMS.md`, etc. |

---

## Spec version

- **Spec version:** 1.0
- **Based on:** django-U-Panel monorepo state as of 2026-10-20
- **Target product name:** QAAT
