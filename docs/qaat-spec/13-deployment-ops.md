# 13 — Deployment & Ops

QAAT runs the same operational topology as django-U-Panel (web + worker + beat + db + redis + nginx) but split into **Go API**, **Python workers**, **Filament admin**, and **Flutter web** build. This document covers environments, containers, env vars, and ops procedures.

**Current sources:** `docker-compose.yml`, `docker-compose.prod.yml`, `backend/Dockerfile`, `backend/entrypoint.sh`, `config/nginx/`, `config/deploy.yml` (Kamal), `scripts/contabo/`, `docs/DEPLOYMENT.md`, `docs/SERVER_SETUP.md`, `docs/WEB_DEPLOYMENT.md`, `.env.production.example`.

---

## 1. Environments

| Env | DB | Hosts | Notes |
|---|---|---|---|
| **Dev** | SQLite (or local Postgres) | localhost | `docker-compose.yml`; runserver/fly; no TLS |
| **Prod** | PostgreSQL 16 | `kiu.orion13.us` → QAAT domain | `docker-compose.prod.yml`; Contabo VPS; Nginx; Cloudflare |

QAAT new prod host placeholder: `qaat.kiu.ac.ug` / `api.qaat.kiu.ac.ug` (or keep `kiu.orion13.us` until cutover — see [14 — Rename](14-rename-migration-playbook.md)).

---

## 2. Container topology (target QAAT)

```
services:
  db:       postgres:16-alpine          # volume postgres_data
  redis:    redis:7-alpine              # appendonly yes, volume
  api:      qaat-api (Go)               # /api/* hot path
  worker:   qaat-worker (Python)        # outbox consumers, email, push, sweeps
  admin:    qaat-admin (Laravel+Filament)  # /admin/*
  web:      nginx (static Flutter web + reverse proxy)
```

Current compose services for reference: `db`, `redis`, `web` (Django runserver/gunicorn), `worker`, `beat`, and prod adds `nginx` (`docker-compose.prod.yml`). QAAT replaces `web` (Django) with `api` (Go) + `admin` (Filament); `beat` duties move into `worker` scheduler (or a tiny `scheduler` sidecar running the Python beat-equivalent).

### 2.1 Dev compose (sketch)

```yaml
services:
  db:
    image: postgres:16-alpine
    environment: [POSTGRES_PASSWORD=qaat, POSTGRES_USER=qaat, POSTGRES_DB=qaat]
    healthcheck: {test: ["CMD-SHELL", "pg_isready -U qaat"], interval: 5s, retries: 10}
  redis:
    image: redis:7-alpine
  api:
    build: ./api            # Go
    environment: [DATABASE_URL=postgres://qaat:qaat@db:5432/qaat, REDIS_URL=redis://redis:6379/0]
    ports: ["8000:8000"]
  worker:
    build: ./worker         # Python
    environment: [DATABASE_URL=..., REDIS_URL=...]
  admin:
    build: ./admin          # Laravel
    ports: ["8080:80"]
```

Prod adds `restart: unless-stopped`, secrets from env file, nginx on 80/443.

### 2.2 Single-binary SQLite mode

For small/self-hosted deploys: Go API can run with `DATABASE=sqlite:///qaat.db`; worker shares the file (WAL mode). Filament points at same SQLite (read-only for dashboards if contention is a concern). Document as "lite" profile.

---

## 3. Nginx routing

Current: `config/nginx/upanel.conf` (upstream `127.0.0.1:8000`, `client_max_body_size 25m`, `/api/health/` access_log off).

QAAT:

| Path | Upstream |
|---|---|
| `/api/` | Go API `:8000` |
| `/admin/` | Filament `:8080` |
| `/` | static Flutter web build (or CDN) |
| `/api/health/` | Go (log off) |

TLS: Cloudflare Flexible/Full or Let's Encrypt via certbot (`scripts/contabo/setup-https.sh`, `setup-cloudflare-https.sh`). CSRF/secure-cookie rules port from Django settings comments (SameSite=Lax mobile/Cloudflare fix).

---

## 4. Environment variables

Port of `backend/.env.example` + `.env.production.example`, renamed `upanel`→`qaat` and split by service.

### 4.1 Shared

| Var | Purpose |
|---|---|
| `DATABASE_URL` | Postgres URL; empty/`DJANGO_USE_SQLITE` equivalent → SQLite path |
| `REDIS_URL` | cache + optional queue |
| `PUBLIC_API_URL` | base for email links (`https://qaat.kiu.ac.ug`) |
| `APP_RETURN_URL` | deep-link target (`qaat://open/email-verified` or https app link) |
| `APP_ANDROID_PACKAGE` | `com.qaat...` |
| `SENTRY_DSN` / `SENTRY_ENVIRONMENT` | error tracking |
| `ONESIGNAL_APP_ID` / `ONESIGNAL_REST_API_KEY` | push |
| `TZ` | default UTC |

### 4.2 Email (worker)

| Var | Purpose |
|---|---|
| `MAILJET_API_KEY` / `MAILJET_SECRET_KEY` | preferred |
| `EMAIL_HOST` / `EMAIL_PORT` / `EMAIL_HOST_USER` / `EMAIL_HOST_PASSWORD` / `EMAIL_USE_TLS` / `EMAIL_USE_SSL` | SMTP fallback |
| `EMAIL_FROM_NAME` / `EMAIL_FROM_ADDRESS` / `DEFAULT_FROM_EMAIL` | from |
| `EMAIL_LOGO_URL` | branding |

### 4.3 Go API

| Var | Purpose |
|---|---|
| `QAAT_API_ADDR` | listen addr (`:8000`) |
| `QAAT_TOKEN_PEPPER` / `JWT_SECRET` | if JWT chosen |
| `QAAT_COLLECTION_WHITELIST` | optional strict collection list |
| `QAAT_ALLOW_INLINE_ADJUDICATION` | default true |

### 4.4 Filament admin

| Var | Purpose |
|---|---|
| `APP_KEY` | Laravel |
| `ADMIN_SESSION_DOMAIN` | cookie domain |
| `FILAMENT_PATH` | default `admin` |

Full list lives in each service's `.env.example`; this spec fixes the **names and semantics** (no silent renames without updating mobile `--dart-define`).

---

## 5. Build & release

### 5.1 Go API

Multi-stage Dockerfile: `golang:1.22` build → `gcr.io/distroless/static` or alpine runtime; `CGO_ENABLED=0` for SQLite optional (or use `mattn/go-sqlite3` with build tag `sqlite`).

### 5.2 Python worker

`python:3.12-slim`; pip install from `requirements.txt` (fastapi, uvicorn, celery/arq, redis, psycopg, onesignal client, mailjet, sentry-sdk). Entrypoint waits for DB (retry loop) then starts worker + scheduler.

### 5.3 Filament

`php:8.3-fpm` + nginx or apache; composer install; `php artisan migrate --force`; `php artisan filament:upgrade`. Shares DB with Go.

### 5.4 Flutter web

`flutter build web --release --dart-define=API_URL=https://api.qaat... --dart-define=SENTRY_DSN=...`; artifact served by nginx. Current CI: `.github/workflows/deploy-web-app.yml` (GitHub Pages), `sync-contabo-web.yml` (sync to VPS) — port to QAAT repo names.

### 5.5 Mobile stores

- Android: `flutter build appbundle`; applicationId = QAAT package ([14](14-rename-migration-playbook.md)).
- iOS: `flutter build ipa`; bundle id + signing in App Store Connect.

---

## 6. Migrations & seeds

- Go: SQL migrations (golang-migrate / goose) — portable Postgres/SQLite dialects or separate dirs.
- Filament: Laravel migrations for admin-only tables (sessions, activity_log, jobs if used).
- Python: none (reads/writes via shared DB or Go service APIs).
- Seeds: `qaat:seed-demo` (QA user + demo list, [08](08-admin-panel-spec.md) §7).

Entrypoint pattern (current `backend/entrypoint.sh`): wait-for-DB → migrate → collectstatic (Filament) → exec server. QAAT API entrypoint: wait-for-DB → migrate → start.

---

## 7. Ops scripts (port from `scripts/contabo/`)

| Current | QAAT equivalent |
|---|---|
| `bootstrap-server.sh` | install docker, clone QAAT, compose up |
| `finish-server-setup.sh` | createsuperuser / seed admin |
| `deploy-web-on-server.sh` | pull + build compose + migrate |
| `restart-api-containers.sh` | restart api/worker/admin |
| `recover-api-stack.sh` | full stack recovery |
| `diagnose-api-502.sh` / `fix-nginx-502.sh` | same, QAAT upstreams |
| `fix-production-env.sh` | env validation |
| `configure-onesignal.sh` | OneSignal app setup |
| `setup-https.sh` / `setup-cloudflare-https.sh` | TLS |
| `purge-cloudflare-cache.sh` | cache purge |

---

## 8. Monitoring & health

- `/api/health/` (public): `{status, service, push_delivery_configured}`.
- Filament server-health page + JSON (psutil/gopsutil) — [08](08-admin-panel-spec.md) §4.
- Sentry: separate projects for Go / Python / Flutter / Filament; environments `prod`/`staging`/`dev`.
- Structured logs; request id middleware in Go.
- Optional: UptimeRobot/Healthchecks.io ping on `/api/health/`.

---

## 9. Backup & DR

- Postgres: nightly `pg_dump` to object storage (current VPS may already do this — verify in `docs/SERVER_SETUP.md`); retain 14 days.
- Redis: AOF enabled in prod (`--appendonly yes`); not critical-path durable (outbox is in Postgres).
- Hive queues are client-side; no server backup needed.
- Restore runbook: stop api/worker → restore dump → run migrations → start.

---

## 10. Cutover plan (high level)

1. Deploy QAAT stack on staging host with seeded/demo data; run mobile apps against staging (`--dart-define=API_URL`).
2. Feature-parity QA using [07](07-mobile-app-spec.md) §4 checklists.
3. Optional ETL: export U-Panel `ApiDocument` rows → load into QAAT typed tables + documents fallback ([03](03-database.md) §6.2).
4. DNS: lower TTL; switch `api.<domain>` → QAAT Go API; web → Flutter build; admin → Filament.
5. Push: point apps to new OneSignal app (or keep app + update tags if unchanged).
6. Monitor Sentry + health for 48h; keep U-Panel running as read-only rollback for 1 week.
7. Decommission Django containers; archive old repo as `django-U-Panel-legacy`.

Detailed rename steps (identifiers, package ids, domains): [14 — Rename & Migration Playbook](14-rename-migration-playbook.md).
