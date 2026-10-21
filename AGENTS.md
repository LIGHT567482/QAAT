# QAAT — Agent guide

## Source of truth

QAAT is rebuilt per the specification in [`docs/qaat-spec/`](docs/qaat-spec/README.md)
(16 docs, v1.0). Alongside it, our own docs record what we decided:

| Doc | Use it for |
|---|---|
| [docs/qaat-spec/](docs/qaat-spec/README.md) | **Behavior** — schema, API, roles, attendance, offline, deploy, gaps. Read before changing behavior. |
| [docs/architecture.md](docs/architecture.md) | **Stack + deviations**, repo layout, the **attendance merge slot** and the contracts you may not change |
| [docs/roles.md](docs/roles.md) | 5 roles, server-side permission matrix, auth flows |
| [docs/decisions.md](docs/decisions.md) | Rename decisions, open items, data-compatibility strings |

**5 roles**: `student`, `lecturer`, `qa_staff`, `administrator`, `kiu_admin`.
The permission matrix is enforced **server-side**; 403 on violation (spec gap #1/S1).

## ⚠️ The attendance merge slot

`backend/internal/attendance` and the attendance endpoints are stubs returning
`501 "attendance logic pending merge"` until the separate implementation merges in
(per spec doc 06). Do **not** implement attendance logic ad hoc; do **not** remove
the stubs or their routes. Fill the package and flip the stubs — route tables and
client wiring stay untouched so the merge has no conflicts. Contracts and slot
details: [docs/architecture.md §3](docs/architecture.md).

## Spec reading order

1. `docs/qaat-spec/01-system-overview.md` — what QAAT is, users, rename
2. `02-architecture.md` — note: we deviate on the service split ([docs/architecture.md §1](docs/architecture.md))
3. `03-database.md` — schema; `04-backend-api.md` — REST surface
4. `05-auth-and-roles.md` — roles + permission matrix
5. `06-attendance-module.md` — **the core domain** (deep, exact strings)
6. `07`–`15` — mobile, admin, notices, presence, reports, offline, deploy, rename, gaps

`15-gaps-and-fixes.md` is the "must not ship these bugs" backlog.

## Commands

| Command | Action |
|---|---|
| `make up` / `make down` | docker compose up/down (Postgres, backend, web) |
| `make dev-backend` / `make dev-web` / `make dev-mobile` | run each component natively |
| `make dev` | backend + web together |
| `make seed` | create one demo user per role (`qaat-demo-1`) |
| `make test` | `go test ./...` + `pnpm build` + `flutter analyze` + `flutter test` |
| `make lint` | `go vet` + eslint + `flutter analyze` |
| `make help` | list all targets |

## Conventions

- **Go**: one module (`backend/`), Gin, `internal/` for non-exported code; handlers
  thin, logic in packages (`internal/attendance`, `internal/auth`, `internal/store`).
- **Migrations**: portable SQL in `db/migrations/` (Postgres + SQLite — doc 03);
  no BEGIN/COMMIT inside migration files; Go sets timestamps explicitly.
- **IDs**: text/uuid strings, never auto-increment (client-generated epoch-millis ids
  must work — doc 03).
- **Timestamps**: UTC ISO-8601 with milliseconds (accept epoch-ms on input).
- **Errors**: JSON `{"detail": ...}` with the doc 02 §5.5 status codes. Check-in
  rejections are **stored outcomes on the attempt**, not HTTP errors.
- **Web**: pnpm only. **Mobile**: Flutter (`flutter analyze` clean).
- Before writing behavior you haven't read: find it in `docs/qaat-spec/` first.

## Testing

Per spec doc 02 §8: Go table-driven tests for the geofence/device gates, exact-string
tests for all six rejection reasons, Flutter unit tests for roll math (spec doc 11),
auth tests for identifier resolution + rate limits, and role-based **403** tests for
the permission matrix. **Every S1/S2 gap from doc 15 needs an acceptance test** linked
in its PR.
