# 02 — Architecture

## 1. Current architecture (django-U-Panel)

```
┌─────────────────────────────────────────────────────────────┐
│                     Flutter client (lib/)                    │
│  Screens · AttendanceStore (in-memory) · Repositories       │
│  Offline queues (Hive) · OneSignal · Geolocator             │
└───────────────┬─────────────────────────────────────────────┘
                │ HTTPS  (Token auth)
                ▼
┌─────────────────────────────────────────────────────────────┐
│                  Django REST API (backend/)                  │
│  /api/auth/*          accounts app                           │
│  /api/<collection>/*  documents app  ← catch-all router      │
│       │                                                      │
│       ├─ write hooks: check-in processing (Celery/inline)    │
│       ├─ write hooks: missed-session notices                 │
│       └─ write hooks: notice push enqueue                    │
│  Celery worker + beat (Redis)                                │
│  PostgreSQL / SQLite · Redis cache · OneSignal · Mailjet     │
└─────────────────────────────────────────────────────────────┘
```

Key facts about the current backend:

- **Schemaless document store** — one table `documents_apidocument(collection, doc_id, data JSON, created_at, updated_at)` behind a generic REST router (`backend/documents/views.py`).
- **Write hooks as business logic** — side effects run on POST/PATCH/DELETE (check-in adjudication, notices, push). This is how "cloud functions" are implemented without a functions platform.
- **Client is the primary application server** — most behavior (roll computation, geofence pre-checks, offline replay, session lifecycle) lives in Flutter (`lib/features/attendance/`).
- **Celery beat** runs three scheduled jobs (see [04 — Backend API](04-backend-api.md) §7).

---

## 2. Target architecture (QAAT)

### 2.1 Proposed service split

The rebuild uses four runtime components plus data stores:

| Component | Language / framework | Responsibility |
|---|---|---|
| **QAAT API (hot path)** | **Go** (chi/echo/fiber + pgx/sqlite) | Auth token verification, document CRUD router, **check-in adjudication** (synchronous geofence/device/time validation), session/list/record reads, push-device registration |
| **QAAT workers** | **Python** (FastAPI for internal admin-ish endpoints + Celery/Arq/RQ workers) | Notice generation & push fan-out, email (verification/reset), scheduled jobs (awaiting-session sweep, scheduled-notice publisher, session auto-finalizer), report/ETL batch jobs |
| **QAAT admin panel** | **PHP / Laravel + Filament** | Staff-facing admin: users, registrations, documents browser, notices, attendance records, dashboard metrics, server health. Its own session/token auth for staff. |
| **QAAT apps** | **Dart / Flutter** | Android, iOS, web clients — identical feature set to current `lib/` |

Data stores:

| Store | Use |
|---|---|
| **PostgreSQL 16** | Production system of record (API + workers + Filament) |
| **SQLite** | Development / single-node / CI (same schema, portable SQL) |
| **Redis** | Cache, job queue broker (or Postgres-backed queue in minimal deploys) |
| **Hive (client)** | Offline queues in Flutter (unchanged conceptually) |

### 2.2 Why this split

- **Go for the hot path** — check-in adjudication is the highest-throughput, lowest-latency operation (every student in a lecture hall submits within seconds). Go gives predictable latency and easy horizontal scaling behind Nginx.
- **Python for workers** — the current backend is Python; porting Celery tasks, OneSignal client, Mailjet client, and data/report scripts is fastest here. FastAPI keeps one language for internal endpoints the admin panel might call.
- **Filament for admin** — replaces the customized Django admin with a full admin framework (resources, tables, actions, auth, plugins) without hand-rolling.
- **Flutter unchanged** — the mobile app is the largest codebase; keeping Dart preserves the offline queue logic, geofence validation, and roll computation already proven in production.

### 2.3 Component diagram

```
                        ┌──────────────────────┐
          ┌────────────▶│  Flutter apps        │
          │             │  (Android/iOS/web)   │
          │             └──────────┬───────────┘
          │                        │ HTTPS (Token)
          │                        ▼
          │             ┌──────────────────────┐        ┌────────────────┐
          │             │   Nginx / Cloudflare │───────▶│  Go API        │
          │             │   (TLS, routing)     │        │  (hot path)    │
          │             └──────────┬───────────┘        └───────┬────────┘
          │                        │                            │
          │             /admin/*   │                     ┌──────▼──────┐
          │                        │                     │  PostgreSQL  │
          │                        ▼                     │  (or SQLite) │
          │             ┌──────────────────────┐        └──────▲──────┘
          │             │  Filament admin      │               │
          │             │  (Laravel)           │───────────────┤
          │             └──────────────────────┘               │
          │                                                    │
          │             ┌──────────────────────┐               │
          └────────────▶│  Python workers      │───────────────┘
                        │  (jobs, email, push) │
                        └──────────┬───────────┘
                                   │
                        ┌──────────▼───────────┐
                        │ Redis · OneSignal    │
                        │ Mailjet · Sentry     │
                        └──────────────────────┘
```

### 2.4 Routing split (Nginx)

| Path prefix | Backend |
|---|---|
| `/api/` | Go API |
| `/internal/` (worker-only, not public) | Python FastAPI (optional; workers mostly pull from queue) |
| `/admin/` | Filament (Laravel) |
| `/` (static) | Flutter web build (or separate host) |

The Go API owns everything under `/api/` including auth and the document router. Filament talks directly to the same Postgres database (or via internal Python/Go service APIs for writes that need hooks — see §5).

---

## 3. Data-access philosophy: keep documents, add types

The current system stores all domain data as JSON documents in one table. QAAT has two viable mappings:

### Option A — Typed tables + JSON overflow (recommended)

Core entities become real tables with real columns, constraints, and indexes:

```
attendance_lists(id, title, room, lecturer_uid, date, program, courses JSON,
                 year, sem, status, created_by, lecturer_sign_code, ...)
attendance_sessions(id, list_id, session_code, start_time, end_time, status,
                    latitude, longitude, radius_meters, remote_learning,
                    location_metadata_pending, roll_discarded, ...)
attendance_records(session_id, student_id, list_id, course, present,
                   verified, timestamp, latitude, longitude, device_id,
                   PRIMARY KEY (session_id, student_id))
attendance_check_in_attempts(id, session_id, student_id, status,
                   rejection_reason, captured_at, ... )
notices(id, title, body, kind, audience, target_*, scheduled_for,
        send_push, push_sent_at, expires_at, ...)
```

A generic `documents(collection, doc_id, data JSON)` table remains for:

- Backward compatibility during migration (bulk-import old `ApiDocument` rows).
- Unstructured/experimental collections.
- The campus geofence and misc `attendance/health` meta docs.

**Benefits:** real constraints (unique session codes per active session, FK integrity), efficient relational reports, straightforward Postgres/SQLite parity, sane Filament resources.

### Option B — Keep schemaless store

Port the `ApiDocument` + router pattern verbatim to Go (single table with JSON1 extension on SQLite, JSONB on Postgres). Fastest port; weakest validation; keeps the current authorization problem unless the router grows per-collection policy.

**Recommendation:** Option A for QAAT v1, with the generic `documents` table retained as escape hatch. The rest of this spec describes behavior in terms of domain entities; implementers may collapse them into JSON docs if choosing Option B.

---

## 4. Request lifecycle: student check-in (QAAT target)

```
Student taps Check in
        │
        ▼
Flutter: validate code format, acquire GPS, local geofence pre-check
        │
        ▼
POST /api/attendance/check-in-attempts   (Go API, Token auth)
        │
        ▼
Go: inline adjudication (sync — no Celery hop for the happy path)
   1. resolve session (id or code→active session)
   2. studentId present?
   3. session exists?
   4. time window (skew rules)
   5. device uniqueness
   6. geofence (haversine + buffers)
        │
   ┌────┴─────┐
   │ accepted │──────────▶ upsert attendance_records/{sessionId}_{studentId}
   │ rejected │──────────▶ stamp rejectionReason on attempt
   └──────────┘
        │
        ▼
Response {status, record?} → Flutter updates store + UI
        │ (if offline)
        ▼
Hive queue row → drain later via same endpoint
```

**Change vs current:** the current design dispatches adjudication to Celery (async) with inline fallback (`backend/documents/views.py:15-27`). QAAT Go API performs adjudication **synchronously in-request** (it is pure computation over the session + records — no external I/O beyond DB). Celery/Arq remains for: awaiting-session sweep, missed-session notices, push fan-out, email.

If a check-in references a session not yet visible (offline lecturer, `awaitingSession`), the Go API stores the attempt as `pending` and the **Python sweep job** (every 30s) retries linking — same as `documents.sweep_awaiting_session_claims` (`backend/attendance/tasks.py:60-96`).

---

## 5. Cross-cutting concerns

### 5.1 Auth

- Mobile/web: **bearer tokens** (opaque, stored server-side) — same header shape `Authorization: Token <key>` or switch to `Bearer <jwt>`; spec in [05 — Auth & Roles](05-auth-and-roles.md).
- Filament: its own Laravel session auth for staff; separate user table or federated against the shared `users` table via a bridge.
- **Server-side authorization** is mandatory in QAAT (unlike current system): every document-router write checks the caller's role against the collection (see [15 — Gaps](15-gaps-and-fixes.md)).

### 5.2 Hooks / side effects

Current write hooks (check-in, missed-session notice, push enqueue) map to:

| Hook | QAAT implementation |
|---|---|
| Check-in adjudication | Synchronous inside Go API `POST/PATCH` of attempts |
| Missed-session notice | Enqueue job on Go write of `attendance/records` with `present=false`; Python worker creates notice + push |
| Notice push enqueue | Enqueue job on Go write of `notices` with `send_push=true`; Python worker calls OneSignal |
| User profile mirroring | On Go/Filament user create/update: write `accounts/users`, `admins`, `lecturers`, `student-registrations`, `staff-numbers` projections (same as `documents/services/user_sync.py`) |

Implementation options for the Go→Python handoff: Redis queue list, Postgres `jobs` table with `SKIP LOCKED`, or transactional outbox. Spec choice: **Postgres outbox table** (works identically on SQLite dev with a polling worker) — no hard Redis dependency for correctness.

### 5.3 Time and clock

All timestamps **UTC ISO-8601 with milliseconds** (current client uses epoch-ms in places and ISO strings in others; QAAT normalizes to ISO-8601 UTC everywhere, accepting epoch-ms on input for compatibility). Clock-skew rules for check-in are specified in [06 — Attendance](06-attendance-module.md) §5.

### 5.4 IDs

| Entity | ID scheme (QAAT = current for compatibility) |
|---|---|
| Lists, sessions | Epoch-millis string (client-generated) — may switch to ULID/UUIDv7 server-side later |
| Check-in attempts | UUID (server) or client-supplied id (upsert) |
| Records | **`{sessionId}_{studentId}`** (deterministic — do not change) |
| Missed notices | **`missed_{sessionId}_{studentId}`** (deterministic) |
| Users | Stable uid string (current: Django user pk as string) |

### 5.5 Error model

JSON errors, HTTP status codes:

| Code | Meaning |
|---|---|
| 400 | Validation (missing studentId, bad code format) |
| 401 | Bad/missing token |
| 403 | Role not permitted (new in QAAT) |
| 404 | Document/collection not found |
| 409 | Conflict (optional; current system upserts instead) |
| 429 | Rate limit (email resend etc.) |
| 5xx | Internal |

Domain rejections (check-in) are **200-level outcomes on the attempt document**, not HTTP errors — the attempt is stored with `status=rejected` and `rejectionReason` (see [06](06-attendance-module.md) §6). This preserves offline-replay semantics.

### 5.6 Observability

- Sentry for Go + Python + Filament (separate environments).
- Structured logs (JSON) with request id.
- Health endpoints: `/api/health/` (public liveness + push-configured flag), richer staff-only server-health metrics (port of `backend/upanel/server_monitor.py` using gopsutil in Go or psutil in Python).

---

## 6. Current → QAAT component mapping

| Current (`django-U-Panel`) | QAAT |
|---|---|
| `backend/upanel/` (settings, urls, celery) | Go `cmd/api` + Python `workers/` + Laravel `config/` |
| `backend/accounts/` | Go `internal/auth` (API) + Laravel Filament user resources + shared `users` table |
| `backend/documents/` router | Go `internal/docstore` (typed tables + generic documents table) |
| `backend/documents/services/check_in.py` | Go `internal/checkin` (same algorithm — see [06](06-attendance-module.md)) |
| `backend/documents/services/missed_session_notice.py` | Python `workers/notices/missed.py` |
| `backend/documents/services/user_sync.py` | Go hook on user writes + Filament observer |
| `backend/attendance/tasks.py` (Celery beat) | Python workers scheduler (same intervals) |
| `backend/notices/` | Go notice CRUD + Python push worker |
| `backend/campus/` (dormant ORM) | Typed `campus_presence` table; drop dormant ORM |
| `backend/upanel/admin_setup.py` + templates | Filament dashboard + metrics (see [08](08-admin-panel-spec.md)) |
| `backend/upanel/services/onesignal.py` | Python `workers/push/onesignal.py` |
| Django admin | Filament |
| Flutter `lib/` | Flutter `lib/` (ported, renamed to QAAT) |
| Hive queues | Hive queues (same keys + rename migration, see [12](12-offline-and-sync.md)) |

---

## 7. Technology version targets (suggested)

| Piece | Suggested baseline |
|---|---|
| Go | 1.22+ |
| Python | 3.12+ |
| Laravel / Filament | Laravel 11+, Filament 3.x |
| Flutter / Dart | Dart 3.5+, Flutter 3.24+ |
| PostgreSQL | 16 |
| SQLite | 3.45+ (JSON1, UPSERT) |
| Redis | 7 (optional if using Postgres-only queue) |

Exact versions are implementer's choice; the spec only requires the features used (JSON columns, UPSERT, `SKIP LOCKED` on Postgres, background isolates/Workmanager on Flutter).

---

## 8. Testing strategy for the rebuild

Port the existing test suites as acceptance tests:

| Current test | QAAT equivalent |
|---|---|
| `backend/documents/tests/test_check_in_geofence.py` | Go table-driven tests for geofence gate |
| `backend/documents/tests/test_check_in_device.py` | Go tests for device-uniqueness gate |
| `backend/documents/tests/test_missed_session_notice.py` | Python worker tests + Go hook enqueue test |
| `backend/documents/tests/test_filters.py` | Go router filter tests (string vs numeric coercion) |
| `backend/accounts/tests/*` | Go auth tests (identifier resolution, reset/verify rate limits) |
| Flutter `test/check_in_validation_test.dart` etc. | Flutter widget/unit tests (carry over) |

Golden rule: **every rejection string and user-facing message in [06](06-attendance-module.md) must appear in at least one test.**
