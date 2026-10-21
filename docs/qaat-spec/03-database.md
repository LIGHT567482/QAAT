# 03 — Database

## 1. Strategy

QAAT runs on **PostgreSQL 16** in production and **SQLite** in development/CI. Both engines must support the same logical schema.

Recommended mapping (Option A from [02 — Architecture](02-architecture.md) §3): **typed tables for core entities** + a generic `documents` table for the schemaless escape hatch (and for importing existing U-Panel `ApiDocument` rows during migration).

Type mapping rules:

| Logical type | Postgres | SQLite |
|---|---|---|
| `uuid` | `UUID` (default `gen_random_uuid()`) | `TEXT` (app-generated) |
| `text` | `TEXT` | `TEXT` |
| `citext_lower` (case-insensitive keys) | `CITEXT` or `LOWER()` unique index | `TEXT` + `COLLATE NOCASE` / stored lowercase |
| `int` / `bigint` | `INTEGER` / `BIGINT` | `INTEGER` / `INTEGER` (rowid) |
| `bool` | `BOOLEAN` | `INTEGER` 0/1 |
| `timestamp` | `TIMESTAMPTZ` | `TEXT` ISO-8601 UTC (app-formatted) |
| `float` | `DOUBLE PRECISION` | `REAL` |
| `json` | `JSONB` | `TEXT` (JSON1) |
| `date` | `DATE` | `TEXT` `YYYY-MM-DD` |

All primary keys are text/uuid strings (never auto-increment integers) so client-generated ids (epoch-millis strings) work as in the current document store.

---

## 2. Identity & accounts

### 2.1 `users`

Port of Django `accounts.User` (`backend/accounts/models.py`).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | stable uid used in `accounts/users/{id}` docs and `lecturerUid`/`studentId` fields |
| `username` | text UNIQUE | currently = email for students; may equal staff number |
| `email` | text UNIQUE, lower() index | |
| `password_hash` | text | argon2id/bcrypt |
| `full_name` | text | |
| `role` | text CHECK IN ('student','lecturer','qa_staff','administrator','kiu_admin') | default `'student'` |
| `registration_number` | text NULL, indexed | student reg no (e.g. `KIU3454S`) |
| `staff_number` | text NULL, unique, indexed | e.g. `KIU-0001` |
| `kiu_admin_job_title` | text NULL | |
| `kiu_admin_onboarding_complete` | bool default false | |
| `email_verified` | bool default false | |
| `is_active` | bool default true | |
| `is_staff` / `is_superuser` | bool | gate Filament staff access |
| `created_at` / `updated_at` | timestamptz | |

Derived flags (computed, not stored): `is_administrator` = role IN (administrator, qa_staff, kiu_admin); `is_lecturer`; `is_student`.

### 2.2 `student_registrations`

Claims on registration numbers (current `StudentRegistration`).

| Column | Type | Notes |
|---|---|---|
| `registration_number` | text PK (uppercased) | unique claim |
| `user_id` | uuid FK → users, NULL | set when claimed |
| `email_verified_at_link` | timestamptz NULL | |
| `created_at` | timestamptz | |

### 2.3 `staff_numbers`

| Column | Type | Notes |
|---|---|---|
| `staff_number` | text PK (uppercased) | `KIU-0001` format |
| `user_id` | uuid FK NULL | |
| `email` / `full_name` | text | mirrored for list views |

Allocation is client-side counter against `accounts/staff-numbers` docs (current behavior); QAAT may add a server allocator endpoint but must keep the doc-compatible shape.

### 2.4 `auth_tokens`

| Column | Type | Notes |
|---|---|---|
| `key` | text PK | opaque token |
| `user_id` | uuid FK, indexed | one active token per user (current behavior); allow multiple with `last_used_at` as enhancement |
| `created_at` | timestamptz | |

### 2.5 `email_verification_tokens` / `password_reset_tokens`

Port of current models (`backend/accounts/models.py`).

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `user_id` | uuid FK, indexed | |
| `token_hash` | text (sha256 hex), unique | raw token only in email link |
| `expires_at` | timestamptz | verification 48h; reset 2h |
| `used_at` | timestamptz NULL | single-use |
| `created_at` | timestamptz | |

### 2.6 `push_devices`

| Column | Type | Notes |
|---|---|---|
| `player_id` | text PK | OneSignal player id |
| `user_id` | uuid FK, indexed | |
| `platform` | text | android/ios/web/windows/macos/linux/unknown |
| `tags` | json | OneSignal tags the client set |
| `created_at` / `updated_at` | timestamptz | |

---

## 3. Attendance domain

Field names in camelCase JSON payloads (current client/server convention). Table columns below use snake_case; the API layer converts.

### 3.1 `attendance_lists`

Payload shape (see seed `backend/accounts/management/commands/seed_demo_attendance_list.py` and client `lib/features/attendance/models/attendance_models.dart`):

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | epoch-millis string (client) |
| `title` / `name` | text | lesson title |
| `room` | text | |
| `time` | text | lesson time label (e.g. "08:00-10:00") |
| `who_taught` | text | lecturer display name |
| `date` | date text `YYYY-MM-DD` | |
| `program` | text | e.g. day / weekend program |
| `courses` | json array of strings | |
| `year` / `sem` | text/int | academic year & semester |
| `status` | text | `draft`/`active`/… (list lifecycle) |
| `created_by` | text | uid |
| `lecturer_uid` | text, indexed | owner lecturer |
| `expected_participants` | int NULL | |
| `lecturer_sign_code` | text NULL | 4–8 char code; lecturer enters to sign in as owner |
| `lecturer_signed_at` | timestamptz NULL | |
| `course_unit_name` | text NULL | |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(lecturer_uid, date)`, `(date)`, `(status)`.

### 3.2 `attendance_sessions`

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | epoch-millis string |
| `list_id` | text FK → lists, indexed | |
| `session_code` | text, indexed | join code `A12B` (normalized uppercase) |
| `start_time` / `end_time` | timestamptz | |
| `status` | text | `active` ∥ `closed` (current client enum `SessionStatus`) |
| `latitude` / `longitude` | double | geofence centre |
| `radius_meters` | int | 100 / 200 / 500 / 1500 typical |
| `remote_learning` | bool default false | skip geofence |
| `location_metadata_pending` | bool default false | GPS failed at creation → skip geofence |
| `roll_discarded` | bool default false | "end without saving" |
| `session_gps_accuracy_meters` | double NULL | lecturer device accuracy at start |
| `created_by` | text | lecturer uid |
| `finalized` | bool default false | |
| `created_at` / `updated_at` | timestamptz | |

Indexes:

- btree `(session_code)` where `status='active'` (partial; Postgres `WHERE status = 'active'`; SQLite partial index equivalent)
- `(list_id, status)`
- `(status, end_time)` for sweep queries

**Uniqueness rule (QAAT hardening):** no two `active` sessions may share the same `session_code`. Enforce with a partial unique index (Postgres) or an application-level check + trigger (SQLite). Current system only checks at client generation time (see [06](06-attendance-module.md) §3).

### 3.3 `attendance_students` (roster entries)

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | client-generated |
| `list_id` | text, indexed | |
| `student_uid` | text, indexed | user id |
| `registration_number` | text, indexed | |
| `full_name` | text | |
| `course` | text | chosen course on the list |
| `three_digit_code` | text | 100–999 roster code |
| `initials` | text | 2–4 uppercase letters |
| `created_at` | timestamptz | |

Unique: `(list_id, student_uid)`.

### 3.4 `attendance_sign_ins`

A student signing into (enrolling on) a list.

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | |
| `list_id` | text, indexed | |
| `student_uid` | text, indexed | |
| `registration_number` | text | |
| `course` | text | |
| `created_at` | timestamptz | |

Unique: `(list_id, student_uid)`.

### 3.5 `attendance_records` (authoritative outcomes)

Doc id **`{sessionId}_{studentId}`** — composite PK `(session_id, student_id)`.

| Field | Type | Notes |
|---|---|---|
| `session_id` | text | part of PK |
| `student_id` | text | part of PK |
| `list_id` | text, indexed | |
| `course` | text default `'—'` | |
| `present` | bool | true = attended; false = explicit absent (lecturer-marked or grace-expired) |
| `verified` | bool | server-adjudicated vs unverified local |
| `timestamp` | timestamptz | capture or adjudication time |
| `latitude` / `longitude` | double NULL | |
| `device_id` | text NULL | for anti-sharing checks |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(session_id)`, `(list_id)`, `(student_id)`, partial index on `(session_id) WHERE present = true` for device-uniqueness queries.

**Merge/overwrite rule:** verified present > unverified present > absent (newest timestamp wins between two absents) — see [11 — Reports](11-reports-and-roll.md) §2.

### 3.6 `attendance_check_in_attempts`

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | client or server generated |
| `session_id` | text NULL, indexed | |
| `session_code_raw` | text NULL | typed code before linking |
| `list_id` | text NULL | |
| `student_id` | text NULL | |
| `device_id` | text NULL | |
| `course` | text NULL | |
| `status` | text | `pending` ∥ `accepted` ∥ `rejected` |
| `rejection_reason` | text NULL | exact strings in [06](06-attendance-module.md) §6 |
| `awaiting_session` | bool default false | lecturer hadn't started yet |
| `captured_at` | timestamptz NULL | student-device time |
| `client_submitted_at` | timestamptz NULL | upload time (skew detection) |
| `latitude` / `longitude` | double NULL | |
| `gps_accuracy_meters` | double NULL | |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(status, awaiting_session, created_at)` for the 30s sweep; `(session_id, device_id)`.

---

## 4. Notices domain

### 4.1 `notices`

| Field | Type | Notes |
|---|---|---|
| `id` | text PK | e.g. `missed_{sessionId}_{studentId}` or UUID |
| `title` | text | |
| `body` | text | |
| `kind` | text | `missedSession`, `sessionCode`, `lecturerTakeAttendance`, `qaStartAttendance`, generic |
| `audience` | text | `all` ∥ `classList` ∥ `student` ∥ `kiuAdmins` (default broadcast) |
| `target_list_id` | text NULL | when audience=classList |
| `target_student_id` | text NULL | when audience=student |
| `target_lecturer_uid` | text NULL | when targeting one lecturer (tag `lec_<uid>`) |
| `session_code` | text NULL | copy helper |
| `session_id` | text NULL | |
| `scheduled_for` | timestamptz NULL | future publish |
| `send_push` | bool default false | |
| `push_sent_at` | timestamptz NULL | idempotency stamp |
| `expires_at` | timestamptz NULL | client-side display expiry (14 days for missed-session) |
| `author` | text | uid or `"QAAT"` system |
| `created_at` / `updated_at` | timestamptz | |

Indexes: `(scheduled_for) WHERE send_push AND push_sent_at IS NULL`; `(kind, created_at)`.

---

## 5. Campus domain

### 5.1 `campus_presence`

| Field | Type | Notes |
|---|---|---|
| `id` | uuid/text PK | |
| `admin_uid` | text, indexed | |
| `event_type` | text | check-in / check-out / override |
| `latitude` / `longitude` | double | |
| `captured_at` | timestamptz | |
| `local_date_key` | text `YYYY-MM-DD` | grouping key (device local date) |
| `metadata` | json | accuracy, device, notes |
| `created_at` | timestamptz | |

Indexes: `(admin_uid, local_date_key)`, `(local_date_key)`.

### 5.2 `campus_geofence` (singleton config)

Currently a document `attendance/health` → `campus/geofence`. QAAT may keep it as a document row or a one-row table:

| Field | Type |
|---|---|
| `latitude` / `longitude` | double |
| `radius_meters` | int (default 200; QA min 1500 in client) |
| `label` | text |
| `updated_at` | timestamptz |
| `updated_by_uid` / `updated_by_name` | text |

---

## 6. Generic documents (escape hatch + migration)

### 6.1 `documents`

Port of `ApiDocument` (`backend/documents/models.py`):

| Column | Type | Notes |
|---|---|---|
| `collection` | text | e.g. `attendance/lists` |
| `doc_id` | text | |
| `data` | json | arbitrary object |
| `created_at` / `updated_at` | timestamptz | |

Unique: `(collection, doc_id)`. Index: `(collection, updated_at)`; GIN on `data` (Postgres) / expression index or none (SQLite).

Used for:

- Imported legacy U-Panel rows during migration.
- Collections QAAT chooses not to type in v1 (`attendance/health` meta docs, experiments).

### 6.2 Migration note

Bulk-import script: read `documents_apidocument` → split into typed tables by collection name; remainder stays in `documents`. Preserve `id` inside `data` as PK. Run verification queries (row counts per collection) after import.

---

## 7. Job / outbox table (async side effects)

QAAT Go API enqueues worker jobs transactionally with domain writes:

### 7.1 `job_outbox`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | |
| `topic` | text | `missed_session_notice`, `notice_push`, `send_verification_email`, `send_password_reset_email`, `user_projection` |
| `payload` | json | e.g. `{recordKey}` or `{noticeId}` |
| `status` | text | `pending` ∥ `processing` ∥ `done` ∥ `failed` |
| `attempts` | int | |
| `run_at` | timestamptz | for retry backoff |
| `created_at` / `updated_at` | timestamptz | |

Python workers poll with `SELECT … FOR UPDATE SKIP LOCKED` (Postgres) or `BEGIN IMMEDIATE` (SQLite). This replaces Redis-as-broker for correctness; Redis remains optional for rate limiting/cache.

---

## 8. Schema DDL sketch (portable)

Illustrative Postgres-first DDL (SQLite adaptations noted in comments):

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  email         TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  full_name     TEXT NOT NULL DEFAULT '',
  role          TEXT NOT NULL DEFAULT 'student'
                CHECK (role IN ('student','lecturer','qa_staff','administrator','kiu_admin')),
  registration_number TEXT,
  staff_number  TEXT UNIQUE,
  email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  is_staff      BOOLEAN NOT NULL DEFAULT FALSE,
  is_superuser  BOOLEAN NOT NULL DEFAULT FALSE,
  kiu_admin_job_title TEXT,
  kiu_admin_onboarding_complete BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX users_email_lower ON users (LOWER(email));

CREATE TABLE attendance_records (
  session_id TEXT NOT NULL,
  student_id TEXT NOT NULL,
  list_id    TEXT NOT NULL,
  course     TEXT NOT NULL DEFAULT '—',
  present    BOOLEAN NOT NULL,
  verified   BOOLEAN NOT NULL DEFAULT FALSE,
  timestamp  TIMESTAMPTZ,
  latitude   DOUBLE PRECISION,
  longitude  DOUBLE PRECISION,
  device_id  TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (session_id, student_id)
);
CREATE INDEX attendance_records_session_idx ON attendance_records (session_id);

-- Active session-code uniqueness (Postgres):
CREATE UNIQUE INDEX attendance_sessions_active_code_uniq
  ON attendance_sessions (session_code) WHERE status = 'active';

-- SQLite equivalent:
-- CREATE UNIQUE INDEX attendance_sessions_active_code_uniq
--   ON attendance_sessions (session_code) WHERE status = 'active';
```

(Full DDL generated by migrations in the QAAT repos — this spec fixes names, types, and constraints.)

---

## 9. Seed data (from current repo)

QAAT dev seed should replicate:

- QA demo user: login `KIU-0001`, email `kiu0001@staff.upanel.local` → QAAT synthetic domain `@staff.qaat.local`, role `qa_staff`, verified (`backend/accounts/management/commands/seed_qa_demo_user.py`).
- Demo attendance list: `demo-attendance-list` with courses, year/sem, lecturer sign code (`seed_demo_attendance_list.py`).

Synthetic staff email domain changes from `staff.upanel.local` to `staff.qaat.local` (see [14 — Rename](14-rename-migration-playbook.md)); password-reset emails must continue to ignore this domain.
