# QAAT — Decisions

Recorded build decisions for this repo. The spec's
[14 — Rename & Migration Playbook](qaat-spec/14-rename-migration-playbook.md)
instructs: *"Record decisions in a `RENAME_DECISIONS.md` at repo root or in this
spec."* — this file is that record (kept under `docs/` for a tidy root).

- Stack & deviations → [architecture.md](architecture.md)
- Roles & permissions → [roles.md](roles.md)

- **Spec version:** 1.0 ([docs/qaat-spec/](qaat-spec/README.md), based on the
  `django-U-Panel` monorepo state as of 2026-10-20)
- **Decided:** 2026-10-21

---

## 1. Phase 0 checklist (spec playbook)

| Decision | Value | Status |
|---|---|---|
| Product name | **QAAT** | ✅ decided |
| Repo name | **QAAT** (this repo; GitHub `LIGHT567482/QAAT`) | ✅ decided |
| Dart package name | `qaat` | ✅ decided |
| Android applicationId | e.g. `ug.kiu.qaat` | ⬜ **OPEN** — pick once, then freeze |
| iOS bundle id | same as applicationId | ⬜ **OPEN** (follows above) |
| Deep-link scheme | `qaat://` | ✅ decided |
| Public domains | keep `kiu.orion13.us` during transition; final `qaat.kiu.ac.ug` / `api.qaat.kiu.ac.ug` | ⬜ **OPEN** |
| Synthetic staff email domain | `@staff.qaat.local` | ✅ decided |
| OneSignal app | new QAAT app (tags grammar unchanged) | ⬜ **OPEN** — create console app |
| Sentry projects | `qaat-api`, `qaat-flutter`, `qaat-web` (no Python worker) | ⬜ **OPEN** |
| Hive box name | `qaat_attendance_queues` (read-fallback from `u_panel_attendance_queues`) | ✅ decided |
| Worker app name | n/a — no Python worker (see [architecture.md](architecture.md)) | ✅ n/a |
| DB engine split | Postgres (prod) + **SQLite (dev/CI)**, one portable schema | ✅ decided (spec gap #23) |

## 2. Data-compatibility strings (never change)

Document collection names, field names (`sessionCode`, `studentId`, …), the
OneSignal tag grammar, the `{sessionId}_{studentId}` record id scheme, and the
`A12B` join-code format are all locked for compatibility. See
[architecture.md §3](architecture.md) for the full behavioral-contract list.

## 3. Related backlogs

- **Spec gap backlog**: [15 — Gaps & Fixes](qaat-spec/15-gaps-and-fixes.md) —
  the "must not ship these bugs" list. **S1 = server-side authorization** (already
  enforced in this build — see [roles.md §3](roles.md)).
- **Rename runbook**: [spec doc 14](qaat-spec/14-rename-migration-playbook.md).
