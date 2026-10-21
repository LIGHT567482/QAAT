# 04 — Backend API

Complete REST surface for QAAT. Based on the current Django API (`backend/upanel/`, `backend/accounts/urls.py`, `backend/documents/`) reimplemented by the Go API (plus Filament for admin-only operations, [08](08-admin-panel-spec.md)).

Base URL: `https://<qaat-host>/api`  
Auth header (current): `Authorization: Token <key>` — QAAT may adopt `Bearer <jwt>` but must document the chosen scheme in the mobile client config (`lib/core/api/api_config.dart`).

All request/response bodies are JSON unless noted.

---

## 1. Root & health

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/api/` | public | Service descriptor JSON (name, version, docs link) |
| GET | `/api/health/` | public | `{ "status":"ok", "service":"qaat-api", "push_delivery_configured": bool }` |
| GET | `/api/client-config/` | public | `{ "onesignal_app_id": str, "push_enabled": bool, "push_delivery_configured": bool }` — no secrets |

Current: `backend/upanel/health_urls.py`, `backend/upanel/client_config.py`.

---

## 2. Auth

Mounted from `backend/accounts/urls.py`. Full behavior in [05 — Auth & Roles](05-auth-and-roles.md).

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/auth/login/` | public | identifier + password → `{token, user}` |
| POST | `/api/auth/register/` | public | create student account → 201 `{token, user}` + queue verification email |
| POST | `/api/auth/logout/` | token | delete token → 204 |
| GET | `/api/auth/me/` | token | profile |
| PATCH | `/api/auth/me/` | token | update `full_name` only |
| DELETE | `/api/auth/me/` | token | delete tokens + account → 204 |
| POST | `/api/auth/password-reset/` | public | rate-limited; always generic response |
| GET | `/api/auth/password-reset/confirm/?token=` | public | **HTML** reset form page |
| POST | `/api/auth/password-reset/confirm/` | public | `{token,new_password,confirm_password}` → HTML result page |
| POST | `/api/auth/password-change/` | token | `{current_password,new_password}` → `{token}` (rotates) |
| POST | `/api/auth/change-password/` | token | alias of password-change |
| POST | `/api/auth/request-verification/` | token | resend verification (rate-limited) |
| GET | `/api/auth/verify-email/?token=` | public | **HTML** verification result + deep link (`APP_RETURN_URL`) |
| POST | `/api/push/register/` | token | `{player_id, platform, tags}` upsert |
| DELETE | `/api/push/register/?player_id=` | token | unregister |

Login identifiers accepted (current `backend/accounts/services/login_identifier.py`):

1. Email (case-insensitive).
2. Student registration number (e.g. `KIU3454S`).
3. Staff number (`KIU-0001`, `KIU0001`, `0001` → normalized `KIU-####`).
4. Synthetic staff email `<staff>@staff.qaat.local` (QAAT rename of `staff.upanel.local`).

Error: always HTTP 401 `"Wrong email or password."` (no user enumeration).

---

## 3. Document router (workhorse)

`GET|POST|PATCH|DELETE /api/<collection>[/<doc_id>]`

Current implementation: `backend/documents/views.py` (`DocumentRouterView`), routed last in `backend/upanel/api_urls.py`, URL pattern `backend/documents/urls.py`.

### 3.1 Semantics

| Method | Path shape | Behavior |
|---|---|---|
| GET | `/api/<collection>/` | List: filter + order + limit → `[{...data, "id": doc_id}]` |
| GET | `/api/<collection>/<doc_id>/` | Get one → `{...data, "id": doc_id}` or 404 `{"detail":"Not found."}` |
| POST | `/api/<collection>/` | Upsert by `id` in body (else server UUID); 201 created / 200 existing; runs write hooks |
| POST | `/api/<collection>/<doc_id>/` | Upsert/replace at that id (body `id` ignored); 201/200; hooks |
| PATCH | `/api/<collection>/<doc_id>/` | Shallow merge; JSON `null` values **delete** keys; creates doc if missing; hooks |
| DELETE | `/api/<collection>/<doc_id>/` | 204 / 404 |
| — | collection-only PATCH/DELETE | 404 (not supported) |

### 3.2 Query parameters (lists)

| Param | Meaning |
|---|---|
| `<field>=<value>` | Equality on `data->field` (values kept as **strings** — critical for uid fields; see `backend/documents/filters.py:71-78`) |
| `<field>__in=a,b,c` | In-list |
| `<field>__gt/__gte/__lt/__lte=` | Numeric/bool comparison |
| `ordering=field` or `-field` | Sort (tie-break `doc_id`) |
| `limit=N` | 1–500, default 100 |

Default order: `-updated_at, doc_id`.

**QAAT addition (recommended):** cursor pagination (`cursor=`) in addition to `limit` for large lists; not required for parity.

### 3.3 Write hooks (side effects)

Runs on successful POST/PATCH that changes data:

1. **`attendance/check-in-attempts`** — adjudicate the attempt (see [06 — Attendance](06-attendance-module.md)). Current: Celery with inline fallback (`backend/documents/views.py:15-27`). QAAT: synchronous in Go API.
2. **`attendance/records`** — if `present` is false (bool or string `"false"`), enqueue **missed-session notice** (current: `backend/documents/services/missed_session_notice.py`).
3. **`notices`** — if `sendPush` true and `pushSentAt` empty and live (no future `scheduledFor`), enqueue **OneSignal push** (current: `backend/notices/push_from_document.py`).

Hooks are idempotent; re-running on the same final state must not duplicate records, notices, or pushes (deterministic ids + `push_sent_at` stamp).

### 3.4 Known collections (client-facing)

From `lib/core/api/api_collections.dart` and `backend/documents/routing.py`:

```
attendance/lists
attendance/sessions
attendance/records
attendance/check-in-attempts
attendance/students
attendance/sign-ins
attendance/health          (meta docs incl. campus/geofence, connectivity, lecturer_staff_counter)
notices
accounts/users
accounts/admins
accounts/lecturers
accounts/staff-numbers
accounts/student-registrations
campus/presence
```

Any other single-segment path is a valid collection (current router creates unknown collections freely). QAAT should **whitelist** collections in the Go router and reject unknown names with 400 (recommended hardening; see [15 — Gaps](15-gaps-and-fixes.md)) — but keep the 14 above working.

### 3.5 Authorization (QAAT requirement)

Every document-router operation must check caller role → collection permission. Minimum matrix (see [05](05-auth-and-roles.md) §3 for full matrix):

| Collection | student | lecturer | qa_staff / administrator / kiu_admin |
|---|---|---|---|
| `attendance/lists` | read (own sign-ins' lists); create only for self-enrollment flows | full CRUD on assigned lists | full |
| `attendance/sessions` | read; create not allowed | full CRUD | full |
| `attendance/check-in-attempts` | create own; read own | read for own lists | full |
| `attendance/records` | read own | read/write (mark absent) for own lists | full |
| `attendance/students`, `attendance/sign-ins` | create/read own | read own lists | full |
| `notices` | read (audience-filtered server-side — QAAT improvement); no create | create (scoped audiences) | full |
| `accounts/*` | read own projections only | read lecturers | full |
| `campus/presence` | none | none | create/read (admins/KIU admin) |
| `attendance/health` | read geofence | read | full |

The current system has **no** server-side enforcement (see [15](15-gaps-and-fixes.md) §1); QAAT must implement this before production.

---

## 4. Representative payloads

### 4.1 Attendance list

```json
{
  "id": "1729467890123",
  "title": "Data Structures",
  "room": "Block B, Room 12",
  "time": "08:00-10:00",
  "whoTaught": "Dr. N. Mugisha",
  "date": "2026-10-20",
  "program": "day",
  "courses": ["BSC/CS", "BSC/SE"],
  "year": "2",
  "sem": "1",
  "status": "active",
  "createdBy": "<uid>",
  "lecturerUid": "<uid>",
  "lecturerSignCode": "AB12CD",
  "courseUnitName": "Data Structures"
}
```

### 4.2 Session

```json
{
  "id": "1729467900000",
  "listId": "1729467890123",
  "sessionCode": "A12B",
  "startTime": "2026-10-20T08:01:00.000Z",
  "endTime": "2026-10-20T08:16:00.000Z",
  "status": "active",
  "latitude": 0.5432,
  "longitude": 32.5811,
  "radiusMeters": 1500,
  "remoteLearning": false,
  "locationMetadataPending": false,
  "rollDiscarded": false,
  "sessionGpsAccuracyMeters": 12.5,
  "createdBy": "<lecturer-uid>"
}
```

### 4.3 Check-in attempt (client → server)

```json
{
  "id": "1729467912345_stu-uid-1",
  "sessionId": "1729467900000",
  "sessionCodeRaw": "a12b",
  "studentId": "stu-uid-1",
  "listId": "1729467890123",
  "course": "BSC/CS",
  "deviceId": "device-uuid-abc",
  "latitude": 0.5433,
  "longitude": 32.5810,
  "gpsAccuracyMeters": 8.2,
  "capturedAt": "2026-10-20T08:05:12.000Z",
  "clientSubmittedAt": "2026-10-20T08:05:13.100Z",
  "status": "pending",
  "awaitingSession": false
}
```

### 4.4 Check-in attempt (server-adjudicated response)

```json
{
  "id": "1729467912345_stu-uid-1",
  "status": "accepted",
  "sessionId": "1729467900000",
  "listId": "1729467890123",
  "awaitingSession": false
}
```

or on failure:

```json
{
  "status": "rejected",
  "rejectionReason": "outside class location"
}
```

### 4.5 Attendance record (server-written)

```json
{
  "id": "1729467900000_stu-uid-1",
  "sessionId": "1729467900000",
  "studentId": "stu-uid-1",
  "listId": "1729467890123",
  "course": "BSC/CS",
  "present": true,
  "verified": true,
  "timestamp": "2026-10-20T08:05:13.100Z",
  "latitude": 0.5433,
  "longitude": 32.5810,
  "deviceId": "device-uuid-abc"
}
```

### 4.6 Notice

```json
{
  "id": "missed_1729467900000_stu-uid-1",
  "title": "Data Structures — BSC/CS",
  "body": "You were marked absent for this session.",
  "kind": "missedSession",
  "audience": "student",
  "targetStudentId": "stu-uid-1",
  "targetListId": "1729467890123",
  "sessionId": "1729467900000",
  "sendPush": true,
  "pushSentAt": "2026-10-20T09:00:01.000Z",
  "expiresAt": "2026-11-03T00:00:00.000Z",
  "author": "QAAT",
  "createdAt": "2026-10-20T09:00:00.000Z"
}
```

---

## 5. Errors

| HTTP | Body | When |
|---|---|---|
| 400 | `{"detail": "..."}` | Bad input (unknown collection in QAAT whitelist mode, malformed JSON) |
| 401 | `{"detail": "Authentication credentials were not provided."}` | Missing/invalid token |
| 403 | `{"detail": "..."}` | Role not allowed (QAAT) |
| 404 | `{"detail": "Not found."}` | Missing doc |
| 429 | `{"detail": "..."}` | Rate limit (email resend etc.) |
| 500 | `{"detail": "..."}` | Internal |

Check-in domain rejections are **not** HTTP errors — see §3.1 (stored on the attempt).

---

## 6. Rate limits (current behavior to port)

Only email flows are limited (cache-based in Django; QAAT: token bucket in Redis or in-memory):

| Flow | Limit |
|---|---|
| Verification resend | 60s cooldown + 5/hour per user (signup skips cooldown) |
| Password reset request | 60s cooldown + 5/hour per user; synthetic staff emails ignored |

No global API throttling in current system; QAAT may add per-token limits as hardening.

---

## 7. Background jobs (parity list)

Current schedules (`backend/upanel/settings.py:243-259`, tasks in `backend/attendance/tasks.py`, `backend/notices/tasks.py`). QAAT Python workers:

| Job | Interval / trigger | Behavior |
|---|---|---|
| `process_check_in` | inline in Go (happy path); Python sweep for pending | Adjudicate pending attempts |
| `sweep_awaiting_session_claims` | every **30s** | Up to 50 oldest `pending` attempts with `awaitingSession=true` created in last **7 days** → try link by code |
| `publish_due_scheduled` | every **60s** | Notices with `sendPush` + `scheduledFor` ≤ now + no `pushSentAt` → push |
| `push_notice_document` | on outbox enqueue | OneSignal call → stamp `pushSentAt` |
| `send_verification_email` | on register / request-verification | Mailjet (SMTP fallback), retry 3× 60s |
| `send_password_reset_email` | on password-reset request | same |
| `finalize_expired_sessions` | every **120s** | Current task closes **ORM** sessions (dead); QAAT: close **doc/typed** sessions past `end_time` still `active` (recommended fix — see [15](15-gaps-and-fixes.md) §3) |
| `mark_grace_expired_absents` | periodic (client currently drives this) | Convert 7-day-unverified check-ins to `present=false` records (see [11](11-reports-and-roll.md) §3) |

Celery equivalents: `documents.process_check_in_doc`, `documents.sweep_awaiting_session_claims`, `notices.publish_due_scheduled`, `notices.push_notice_document`, `accounts.send_verification_email`, `accounts.send_password_reset_email`, `attendance.finalize_expired_sessions`.

---

## 8. Push-device registration detail

`POST /api/push/register/` body:

```json
{ "player_id": "onesignal-player-id", "platform": "android", "tags": {"stu_<uid>": "1", "list_<id>": "1"} }
```

Upsert by `player_id` (current `backend/accounts/views.py` PushDevice views). DELETE removes by `player_id` (or all for user if omitted).

Tags set client-side must match the OneSignal tag grammar used by the push worker ([09 — Notices & Push](09-notices-and-push.md) §3): `stu_<uid>`, `lec_<uid>`, `list_<listId>`, `kiu_admins`, `all_notices`.

---

## 9. Versioning

Current API is unversioned. QAAT recommendation: keep unversioned for parity but add `X-QAAT-API-Version` response header and a `/api/` descriptor with semver for client feature detection (`lib/core/api/api_config.dart` already tolerates extra fields).
