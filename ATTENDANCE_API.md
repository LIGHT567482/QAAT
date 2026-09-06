> ## ⛔ DEFERRED TO V2 — NOT USED BY THIS VERSION
>
> **v1 of KIU QAAT ships as a self-contained internal Quality Assurance system.** It makes no
> outbound call to U-Panel and serves no U-Panel-sourced row. Nothing in this document is wired
> up: the gateway's U-Panel client, its `/api/v1/dashboard/upanel/attendance` route and every
> U-Panel tab in the dashboards are commented out.
>
> The document is kept, not deleted, because it is the integration contract for v2 — the tokens,
> scopes and payload shapes below are still what the U-Panel side exposes. Restoring the
> integration means uncommenting the route in `backend/api-gateway/internal/router/router.go`,
> the merge helpers in `internal/handlers/`, and the tabs in the dashboards.

# Attendance read API (KIU-QAAT)


Long-lived **Django REST Framework tokens** for reading U-Panel attendance data. Intended for external systems (e.g. KIU-QAAT). Uses the same auth stack as the Flutter app (`Authorization: Token <key>`).

Live attendance is stored as schemaless JSON documents (`documents.ApiDocument`), **not** the unused SQL tables in `backend/attendance/models.py`.

**Production base URL:** `https://kiu.orion13.us`

---

## Authentication

```http
Authorization: Token <key>
```

| Status | Meaning |
|--------|---------|
| `401` | Missing / invalid / rotated-away token |
| `403` | Authenticated but write blocked (service accounts are read-only) |
| `404` | Document missing **or** outside the token’s scope (retrieve) |

Tokens are created with `create_attendance_api_token` (below). Flutter login tokens keep working; this command is for dedicated reader accounts.

---

## Scopes

| CLI `--role` | User roles that match | What GET returns |
|--------------|----------------------|------------------|
| `student` | `student` | Own records / check-in attempts only (`studentId` ∈ registration number, user pk, username). Lists & sessions only when referenced by those records. |
| `lecturer` | `lecturer` | Lists where `lecturerUid` = user pk (or legacy `whoTaught` = full name with empty uid). Sessions for those lists. Records / attempts for those lists or sessions. |
| `admin` | `administrator`, `qa_staff` (and existing `kiu_admin` users for reads) | All attendance collections: lists, sessions, records, check-in-attempts, students, sign-ins. |

`kiu_admin` is treated as **admin-wide** for attendance GET because the Flutter client already loads attendance on the staff bulk path for that role.

### Service accounts (recommended for QAAT)

```text
email: attendance-api-{role}@upanel.internal
password: unusable (no Flutter password login)
writes: rejected on attendance/* (403)
```

Create with `--create-service-user`.

---

## Create / rotate a token

### Contabo (production)

Merge the attendance-API PR, then rebuild so the container has the command:

```bash
cd /opt/upanel
git fetch origin main
git reset --hard origin/main
docker compose -f docker-compose.prod.yml --env-file .env.production build --no-cache web
docker compose -f docker-compose.prod.yml --env-file .env.production up -d web worker beat

docker compose -f docker-compose.prod.yml --env-file .env.production exec web \
  python manage.py create_attendance_api_token --role admin --create-service-user --rotate
```

If you see `Unknown command: 'create_attendance_api_token'`, the running image is still on an older commit — rebuild as above.

### Other examples

```bash
python manage.py create_attendance_api_token --role student --user-id 12
python manage.py create_attendance_api_token --role lecturer --email lecturer@kiu.ac.ug
python manage.py create_attendance_api_token --role admin --email admin@example.com --rotate
python manage.py create_attendance_api_token --role admin --create-service-user --rotate
```

### Output (only these lines; treat `token=` as secret)

```text
role=admin
user_id=42
email=attendance-api-admin@upanel.internal
token=<key>
header=Authorization: Token <key>
scopes=all attendance/lists, sessions, records, …
```

`--rotate` deletes existing tokens for that user first (old key → `401`).

Role mismatch (e.g. `--role admin` on a student user) exits non-zero.

**Do not** commit tokens to git, `.env`, or README.

---

## Endpoints

### 1. Dedicated export (preferred for QAAT)

```http
GET /api/attendance/export/
```

Same role scoping as document GETs. Default `limit` is **1000**, max **5000** (document list endpoints stay capped at 500).

#### Query parameters

| Param | Description |
|-------|-------------|
| `from` | ISO date or datetime — include records with `timestamp` ≥ bound |
| `to` | ISO date or datetime — include records with `timestamp` ≤ bound (date → end of day) |
| `list_id` | Filter records by `listId` |
| `session_id` | Filter records by `sessionId` |
| `student_id` | Filter records by `studentId` |
| `limit` | Page size (1–5000, default 1000) |
| `offset` | Skip N records (default 0) |

Records are ordered by `timestamp` descending (fallback: `updated_at`). Related lists and sessions for the returned page are included.

#### Example

```bash
curl -sS -H "Authorization: Token $TOKEN" \
  "https://kiu.orion13.us/api/attendance/export/?from=2026-03-01&to=2026-03-31&limit=5000"
```

#### Response shape

```json
{
  "lists": [{ "id": "list-a", "lecturerUid": "12", "courseUnitName": "Math", "...": "..." }],
  "sessions": [{ "id": "sess-a", "listId": "list-a", "sessionCode": "JOINAA", "...": "..." }],
  "records": [{
    "id": "sess-a_REG-A",
    "sessionId": "sess-a",
    "studentId": "REG-A",
    "listId": "list-a",
    "course": "Math",
    "timestamp": "2026-03-01T10:00:00+00:00",
    "latitude": 0.35,
    "longitude": 32.58,
    "verified": true,
    "present": true,
    "deviceId": "…"
  }],
  "count": 1234,
  "limit": 5000,
  "offset": 0
}
```

`count` is the total matching records before `limit`/`offset` (use with pagination).

---

### 2. Document collections (scoped GET)

Same paths the Flutter app uses. **GET** is role-scoped for attendance collections. **POST / PATCH / DELETE** stay available for normal app users; **service accounts** get `403` on attendance writes.

| Collection | Path |
|------------|------|
| Lists | `/api/attendance/lists/` |
| Sessions | `/api/attendance/sessions/` |
| Records | `/api/attendance/records/` |
| Check-in attempts | `/api/attendance/check-in-attempts/` |
| Students | `/api/attendance/students/` |
| Sign-ins | `/api/attendance/sign-ins/` |

```http
GET /api/attendance/records/
GET /api/attendance/records/{doc_id}/
```

List query helpers (unchanged): field equality filters on JSON `data`, `ordering`, `limit` (default 100, **max 500**). Prefer `/api/attendance/export/` when you need large roll dumps.

```bash
curl -sS -H "Authorization: Token $TOKEN" \
  "https://kiu.orion13.us/api/attendance/records/?limit=500"

curl -sS -H "Authorization: Token $TOKEN" \
  "https://kiu.orion13.us/api/attendance/lists/list-a/"
```

Out-of-scope retrieve returns **404** (not 403), so callers cannot probe other users’ ids.

Non-attendance collections (e.g. `/api/notices/`) are unchanged by this feature.

---

## Record document shape

Check-in writes:

| Field | Notes |
|-------|--------|
| Collection | `attendance/records` |
| `doc_id` | `{sessionId}_{studentId}` |
| `studentId` | Usually registration number; may also be user id string — student scope matches both |
| `listId` / `sessionId` | Links to list and session docs |
| `timestamp` | ISO datetime used by export `from` / `to` |
| `present` / `verified` | Attendance flags |
| `latitude` / `longitude` / `deviceId` | Check-in evidence |

Lists store `lecturerUid` as the User pk string.

---

## Quick integration checklist (QAAT)

1. Deploy code that includes `create_attendance_api_token` (merge + Contabo rebuild).
2. Create an admin service token with `--create-service-user --rotate`.
3. Store the token in QAAT secrets only.
4. Call `GET /api/attendance/export/` with date / list filters; paginate with `offset` + `limit`.
5. On compromise or rotation policy: run the command again with `--rotate` and update QAAT.

---

## Source

| Piece | Path |
|-------|------|
| Token command | `backend/accounts/management/commands/create_attendance_api_token.py` |
| GET scoping | `backend/documents/attendance_scope.py` |
| Export view | `backend/documents/export.py` |
| Document router | `backend/documents/views.py` |
| Tests | `backend/documents/tests/test_attendance_api_token_scope.py` |

## Related docs

- [Attendance data flow](ATTENDANCE_DATA_FLOW.md) — app-side queues and stores
- [Student check-in flow](STUDENT_CHECK_IN_FLOW.md)
- [Server setup](SERVER_SETUP.md) — Contabo / Docker layout
