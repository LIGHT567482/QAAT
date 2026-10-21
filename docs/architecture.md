# QAAT — Architecture

How QAAT is built in *this* repo, and where we deliberately deviate from the
spec. Behavior/domain rules come from the spec ([docs/qaat-spec/](qaat-spec/README.md));
the stack below is our own. Read this before writing code.

- Roles & permissions → [roles.md](roles.md)
- Rename & open decisions → [decisions.md](decisions.md)

---

## 1. Stack

| Layer | Technology |
|---|---|
| Backend | **Go (Gin)** — one backend for the whole system, with separate API groups per role (`/api/auth`, `/api/student`, `/api/lecturer`, `/api/admin`) |
| Student & lecturer apps | **Dart / Flutter** (Android, iOS, web) |
| Administrator, QA & KIU-admin dashboards | **Next.js** (responsive web; replaces the spec's Filament panel) |
| Database | **PostgreSQL** (production); **SQLite** in dev/CI (dual-engine schema — spec doc 03) |
| Outbox / jobs | Postgres **transactional outbox**, drained in-process by the Go backend at the spec's cadences (30 s sweep, 60 s notice publisher, 120 s finalizer) |
| Push / email | OneSignal, Mailjet (SMTP fallback) |
| Errors / logs | Sentry per service, structured JSON logs with `X-Request-Id` |

### Deviations from the spec (agreed)

The spec (docs 02/08/13) mandates four runtime components. We keep a simpler
stack and use the spec for **behavior/domain rules only**:

| # | Spec mandates | Our build | Spec part kept as contract |
|---|---|---|---|
| 1 | Go API + **Python workers** + **Laravel/Filament** + Flutter | **Single Go (Gin) backend** — one process, role-grouped APIs; outbox jobs run in-process | Postgres transactional outbox semantics; job cadences (30s/60s/120s) |
| 2 | One **Flutter** app for all 5 roles | **Flutter** = student + lecturer; **Next.js** = administrator / QA / KIU-admin dashboards | Mobile feature set of doc 07 for student + lecturer |
| 3 | **Filament** admin panel (13 resources, metrics, server health) | **Next.js** admin surfaces covering the same functionality | Doc 08's resource list = the Next.js page backlog |
| 4 | Generic document router `GET /api/<collection>` | **Per-role API groups** under one Go backend | 14-collection whitelist, permission matrix (doc 05 §3), 403 on role violation, error model (doc 02 §5.5) |
| 5 | Dual-engine **PostgreSQL + SQLite** | Postgres (prod) + **SQLite (dev/CI)**, same schema | Gap backlog item #23 (dual-engine CI) |

Spec components **not** built: Python worker service, Laravel/Filament admin
panel, single-app-all-roles Flutter.

---

## 2. Repository layout

```text
docs/
  qaat-spec/            ⭐ THE SPEC — 16 docs, source of truth for behavior
  architecture.md       ← this file: stack, deviations, layout, attendance merge
  roles.md              roles, permission matrix, auth flows, surfaces
  decisions.md          rename phase-0 decisions + open items
backend/                Go (Gin) backend — auth + per-role API groups
  internal/attendance/  ⚠️ merge slot for the attendance engine (stubs → doc 06)
  cmd/server, cmd/seed  entrypoint + demo-user seeder
frontend/
  mobile/               Flutter app — student + lecturer roles
  web/                  Next.js — administrator / QA / KIU-admin dashboards
db/migrations/          Fresh-schema migrations (typed tables per spec doc 03)
infra/                  docker-compose, Dockerfiles
brand.json              ⭐ single source of branding truth — §4
scripts/brand-sync.mjs  derives every frontend's branding from brand.json
```

The previous (pre-spec) implementation — `backend/auth-service`, `api-gateway`,
`session-manager`, `sync-receiver`, `notification-service`,
`frontend/admin-dashboards`, `student-portal`, `coordinator-*`, and the
RLS/tenant schema in the old `db/migrations/001–111` — was **deleted** in this
rebuild (git history preserves it).

---

## 3. Attendance = the merge slot

The attendance engine is being implemented separately and merged here. The slots:

- **Schema now**: the typed tables from spec doc 03 (`attendance_lists`,
  `attendance_sessions`, `attendance_records`, `attendance_check_in_attempts`,
  `attendance_students`, `attendance_sign_ins`) — created by the Go migrations.
- **Engine slot**: Go `backend/internal/attendance` — `Verify(attempt)` implementing
  gates 0–7, plus the sweeps (`SweepAwaitingSessionClaims` 30 s,
  `FinalizeExpiredSessions` 120 s, `MarkGraceExpiredAbsents` 7-day reaper).
  Every entry point currently returns `ErrNotMerged`.
- **Endpoints**: routed and role-guarded, returning **`501` with
  `"attendance logic pending merge"` + `docs/qaat-spec/06-attendance-module.md`**
  until the merge lands.
- **Clients**: Flutter + Next.js render the attendance screens with an explicit
  pending state; nothing else changes when the logic arrives.

**Merge rule:** fill `backend/internal/attendance/` and flip the stubs — route
tables and client wiring stay untouched so the merge has no conflicts. Do not
implement attendance logic ad hoc; do not remove the stubs or their routes.

### Behavioral contracts you may not "improve"

- The **six exact check-in rejection strings** (doc 06 §4.4)
- Join codes **`A12B`** + legacy `###`/`####`/`L###` acceptance
- Deterministic ids `{sessionId}_{studentId}` / `missed_{sessionId}_{studentId}`
- Three-state roll (Present / Absent / Pending) + **7-day grace** + percentage math (doc 11)
- Offline capture-order invariant + 6 Hive queue keys + drain order (doc 12)
- Auth flows: identifier resolution order, fixed `401`, 48h/2h tokens (doc 05)
- OneSignal tag grammar (`stu_`, `lec_`, `list_`, `kiu_admins`, `all_notices`)

Full logic — codes, lifecycle, adjudication, sweeps, 28 edge cases — is in
[06 — Attendance Module](qaat-spec/06-attendance-module.md).

---

## 4. Branding = one file

**[`brand.json`](../brand.json) at the repo root is the single source of
branding truth.** Crest, badge, logo, header/sidebar/footer/background colours,
text colours, background image (with its blur / brightness / contrast /
overlay), and every brand string are read from it. No screen hardcodes any of
them — rebranding is a one-file edit.

```text
brand.json  ──make brand──►  frontend/web/lib/brand.json          imported by the app
                     ├────►  frontend/web/public/brand/*.png      favicon + <img>
                     ├────►  frontend/mobile/assets/brand/*.png   Flutter image assets
                     └────►  frontend/mobile/lib/core/brand/brand.g.dart   typed Dart consts
```

| Field | Drives |
|---|---|
| `app_name` | Window/app titles, headers, the `QAAT` string everywhere |
| `name`, `motto`, `slogan`, `address` | Subtitles, sidebar, footer |
| `logo_url` / `crest_url` / `badge_url` | Crest + badge (data URI, URL, or `/path`; empty `crest`/`badge` fall back to `logo`, then to each other) |
| `brand_color` | Primary: buttons, accents, links, focus |
| `header_color` | Web app bar; Flutter `AppBar` |
| `sidebar_color` | Web sidebar; Flutter `NavigationBar` (its mobile equivalent) |
| `footer_color` | Web footer; Flutter `BrandFooter` |
| `background_color` | Page background on both surfaces |
| `background_image` + `_blur` / `_brightness` / `_contrast` / `_overlay_color` / `_overlay_opacity` | The layered background (`#brand-background` in CSS; `BrandBackground` in Flutter) |
| `text_color_light` / `text_color_dark` | Body text / text on brand-coloured chrome |

**Consumers.** Web reads `lib/brand.ts` — it also emits the values as CSS
custom properties (`--brand-header`, `--brand-sidebar`, …) into `:root` from
`app/layout.tsx`, and the chrome lives in `components/brand/BrandShell.tsx`.
Flutter reads the generated `QaatBrand` (colours, strings, `crestImage`) plus
`BrandBackground` / `BrandFooter` / `BrandCrest` in `lib/core/brand/`.

**Guarding it.** `make brand` regenerates; `make brand-check` (run by both
`make test` and `make lint`) fails on drift. On mobile,
`test/brand_test.dart` additionally asserts the constants and the bundled crest
bytes still match `brand.json`, and that no screen contains a hex colour
literal. The backend holds no branding today — it gains some when email
templates land, and those must read the same file.

**Known gap.** The Android/iOS launcher icons are still the Flutter defaults.
`flutter_launcher_icons` takes its config from `pubspec.yaml` only (no
external config file), so wiring it up means the sync script having to rewrite
pubspec — and its `adaptive_icon_background` wants a literal colour, which
would break the single-source rule. Do it by generating the pubspec block from
`brand.json`, not by hand.
