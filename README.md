# QAAT — Campus Attendance & Academic Operations

**QAAT** (renamed from **django-U-Panel** / **U-Panel**) is a campus attendance and
academic-operations system for Kampala International University (KIU). It replaces
manual paper registers with:

- **Digital class lists** — lecturers (or QA staff) create lists per lesson (course,
  program, year, semester, room, date).
- **Geofenced check-in sessions** — a lecturer opens a timed session with a join code
  (`A12B`) and a GPS geofence; students check in from inside the classroom area.
- **Roll tracking** — every session produces a three-state roll (**Present / Absent /
  Pending**) per student; attendance percentages feed eligibility decisions, with a
  **7-day grace window** before unresolved check-ins become Absent.
- **Staff campus presence** — administrators/QA check in and out of campus under
  time-based policies (on-time ≤ 08:30, early departure < 17:00, overwork > 17:30).
- **Notices & push** — targeted notifications (all users, one class list, one student,
  KIU admins, one lecturer) via OneSignal, including automated "you missed class" notices.
- **Reporting** — consolidated rolls, lecturer-teaching rolls, staff-presence rolls, CSV/PDF export.

The system is **offline-first** on mobile: students in rooms with poor connectivity
queue check-ins locally and sync when back online.

> **The complete specification lives in [`docs/qaat-spec/`](docs/qaat-spec/README.md)**
> — 16 documents (v1.0, based on the `django-U-Panel` monorepo state as of 2026-10-20).
> It is the source of truth for behavior. Start with
> [01 — System Overview](docs/qaat-spec/01-system-overview.md).

---

## Documentation

| Document | Contents |
|---|---|
| [docs/qaat-spec/](docs/qaat-spec/README.md) | ⭐ **The spec** — behavior, schema, API, roles, attendance engine, offline, deploy, gaps |
| [docs/architecture.md](docs/architecture.md) | Our stack, **deviations from the spec**, repo layout, the attendance merge slot |
| [docs/roles.md](docs/roles.md) | The 5 roles, permission matrix, auth flows, access surfaces |
| [docs/decisions.md](docs/decisions.md) | Phase-0 rename decisions, open items, data-compatibility strings |
| [AGENTS.md](AGENTS.md) | Contributor/agent guide: spec reading order, conventions, commands, testing |

### Core domains

```text
accounts ──▶ users, student-registrations, staff-numbers, push devices, email/reset tokens
   │
   ▼
attendance ──▶ lists ─▶ sessions ─▶ check-in-attempts
   │               │
   │               └─▶ records (present/absent)   id = {sessionId}_{studentId}
   │
   ├─▶ campus presence (staff check-in/out, geofence)
   └─▶ notices (manual + automated missed-session) ─▶ OneSignal push
```

- **List** → one scheduled lesson. **Session** → a live check-in window (join code,
  start/end, GPS centre + radius, `active|closed`).
- **Attempt** → raw student submission (GPS + device id), adjudicated server-side
  through **gates 0–7** into `accepted`/`rejected` with one of six exact rejection
  strings (spec doc 06 §4.4).
- **Record** → authoritative outcome, idempotent on `{sessionId}_{studentId}`.
- **Roll** → students × sessions grid; percentage skips Pending entirely (spec doc 11).

---

## Attendance = the merge slot

The attendance engine is being implemented separately and merged into this repo.
Today: the schema exists (typed tables per spec doc 03), the endpoints are routed
and role-guarded returning **`501` `{"error":"attendance logic pending merge"}`**,
and `backend/internal/attendance` holds `TODO(attendance-merge)` stubs. Clients render
an explicit pending state. Filling the package and flipping the stubs touches no route
files. Details: [docs/architecture.md §3](docs/architecture.md).

---

## Stack (summary)

**Go (Gin)** backend (one service, per-role API groups) · **Flutter** for
student + lecturer · **Next.js** for administrator / QA / KIU-admin dashboards ·
**PostgreSQL** (prod) + **SQLite** (dev/CI). We use the spec for behavior and
deviate deliberately on the service split — see
[docs/architecture.md §1](docs/architecture.md).

---

## Getting started

```bash
# prerequisites: Go 1.27+, Docker, Node 20 + pnpm, Flutter 3.44+
cp .env.example .env

make up            # Postgres + backend + web (builds images)
# — or run natively, no Docker: —
make dev-backend   # Go backend on :8080 (SQLite by default; auto-migrates)
make dev-web       # Next.js dashboards on :3000
make dev-mobile DEVICE=<device>   # Flutter app

make seed          # create one demo user per role (password: qaat-demo-1)
make test          # go test ./... + pnpm build + flutter analyze + flutter test
make lint          # go vet + eslint + flutter analyze
make help          # list all targets
```

Demo logins after `make seed`: `student@kiu.ac.ug` · `lecturer@kiu.ac.ug` ·
`qa@kiu.ac.ug` · `admin@kiu.ac.ug` · `kiuadmin@kiu.ac.ug` — all `qaat-demo-1`.

---

## Repository layout

```text
README.md           ← you are here
AGENTS.md           ← contributor/agent guide
docs/
  qaat-spec/        ⭐ THE SPEC (16 docs, source of truth for behavior)
  architecture.md   stack, deviations, repo layout, attendance merge slot
  roles.md          roles, permission matrix, auth flows, surfaces
  decisions.md      rename decisions + open items
backend/            Go (Gin) backend — auth + per-role API groups
  internal/attendance/   ⚠️ merge slot for the attendance engine (stubs → doc 06)
  cmd/server, cmd/seed   entrypoint + demo-user seeder
frontend/
  mobile/           Flutter — student + lecturer
  web/              Next.js — administrator / QA / KIU-admin dashboards
db/migrations/      fresh-schema migrations (typed tables per spec doc 03)
infra/              docker-compose, Dockerfiles
```

---

## Rename

QAAT was `django-U-Panel`. The rename checklist is
[spec doc 14](docs/qaat-spec/14-rename-migration-playbook.md); this repo's answers
are in [docs/decisions.md](docs/decisions.md).
