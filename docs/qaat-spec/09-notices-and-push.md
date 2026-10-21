# 09 — Notices & Push

QAAT delivers in-app notices and mobile push via OneSignal. Notices cover manual announcements, session-code broadcasts, QA overdue alerts, and automated "you missed class" messages.

**Current sources:** `backend/notices/` (tasks, push_from_document), `backend/documents/services/missed_session_notice.py`, `backend/upanel/services/onesignal.py`, `lib/features/notices/`, `lib/core/push/`.

---

## 1. Notice data model

Collection/table `notices` (see [03 — Database](03-database.md) §4):

| Field | Type | Notes |
|---|---|---|
| `id` | string | UUID or deterministic `missed_{sessionId}_{studentId}` |
| `title` | string | |
| `body` | string | |
| `kind` | string | see §2 |
| `audience` | string | `all` (broadcast), `classList`, `student`, `kiuAdmins` |
| `target_list_id` | string? | audience=classList |
| `target_student_id` | string? | audience=student |
| `target_lecturer_uid` | string? | audience=specific lecturer (tag `lec_<uid>`) |
| `session_code` | string? | copy helper / payload |
| `session_id` | string? | |
| `scheduled_for` | iso? | future publish |
| `send_push` | bool | |
| `push_sent_at` | iso? | idempotency stamp |
| `expires_at` | iso? | client display expiry (14d for missed) |
| `author` | string | uid or `"QAAT"` |
| `created_at` / `updated_at` | iso | |

### 1.1 Notice kinds

| Kind | Source | Purpose |
|---|---|---|
| `missedSession` | **Server-generated** when a record becomes absent | "You were marked absent…" |
| `sessionCode` | Lecturer/QA | Broadcast current join code to class |
| `lecturerTakeAttendance` | System/QA | Remind lecturer to open attendance (tag `lec_<uid>`) |
| `qaStartAttendance` | System | "A lecturer has not opened attendance 1h30m after lesson time…" |
| (generic) | Lecturer/QA/admin | Free-form announcement |

Special push copy defaults (port `push_copy_for_notice`, `backend/notices/push_from_document.py`):

- `sessionCode` — includes the code prominently.
- `lecturerTakeAttendance` — reminder to open attendance.
- `qaStartAttendance` — "A lecturer has not opened attendance 1 hour 30 minutes after lesson time…"
- `missedSession` — missed-class wording.
- Body clamped to **500 chars**.

---

## 2. Audiences & targeting

| Audience | Who receives | OneSignal filter |
|---|---|---|
| `all` (default broadcast) | Everyone with the app | tag `all_notices` |
| `classList` | Everyone signed into / associated with `target_list_id` | tag `list_<sanitizedListId>` |
| `student` | One student (`target_student_id`) | tag `stu_<sanitizedUid>` |
| `kiu_admins` | KIU administrators | tag `kiu_admins` |
| (lecturer target) | One lecturer | tag `lec_<sanitizedUid>` |

Tag sanitization: `[^a-zA-Z0-9\-_.~%] → _` (`sanitize_push_tag_segment`). Tags set client-side on push-device registration ([04 — Backend API](04-backend-api.md) §8) must match this grammar.

**Broadcast vs per-list eligibility** (client `notices_repository.dart`): some kinds (session codes for remote learning) suppress broadcast; enforce server-side in QAAT when creating notices from the lecturer UI.

---

## 3. Push pipeline

### 3.1 Enqueue (write hook)

On create/replace/patch of any `notices` doc (current `maybe_enqueue_notice_push`, `backend/notices/push_from_document.py`):

- If `sendPush` true AND `pushSentAt` empty AND live (`scheduledFor` absent or ≤ now; accepts ms-epoch and ISO) → enqueue job `notices.push_notice_document`.
- QAAT: Go API writes outbox row (topic `notice_push`) transactionally; Python worker drains ([02](02-architecture.md) §5.2).

### 3.2 Scheduled notices

- `notices.publish_due_scheduled` (every **60s**, current `backend/notices/tasks.py`): scans notices with `sendPush` + `scheduledFor` ≤ now + no `pushSentAt` → enqueue push.
- QAAT: same interval; query `WHERE send_push AND push_sent_at IS NULL AND scheduled_for <= now()`.

### 3.3 Send (worker)

`send_notice_push` → OneSignal REST `POST https://api.onesignal.com/notifications`:

- Auth: `Authorization: Key <REST key>` (auto-prefix unless `Key `/`Basic ` present).
- `target_channel: push`, `headings/contents` `{en}`.
- Either `include_player_ids` (≤2000) or `filters` of tag equalities.
- 15s timeout; on failure/unconfigured → return False + log (do not stamp).
- On success → `mark_notice_push_sent` writes `pushSentAt` ISO timestamp (idempotency).

Data payload to app: `noticeId`, `kind`, optional `sessionCode`, `sessionId`.

### 3.4 OneSignal configuration

Env: `ONESIGNAL_APP_ID`, `ONESIGNAL_REST_API_KEY`. Exposed safely (app id only) via `/api/client-config/`. Prod example app id in current settings: `882dcbec-c505-4c12-95c5-78da7e8ef25c`.

QAAT: new OneSignal app (or reuse); update Flutter `--dart-define` / config; re-verify tag registration (`onesignal_integration_verification.dart`).

---

## 4. Missed-session auto-notices

Current: `backend/documents/services/missed_session_notice.py`.

Trigger: any write to `attendance/records` where `present` is boolean `false` **or the string `"false"`** (type-drift tolerance, L20–21), and the record was **not** previously absent (dedupe on update, L67–68).

Behavior:

1. Skip unless collection is `attendance/records` (L61).
2. Deterministic notice doc id **`missed_{sessionId}_{studentId}`** (L75–80); skip if already exists.
3. Build payload (L82–109):
   - `title` = list title (`attendance/lists/{listId}` `title`/`name`) + optional course.
   - `body` = missed-session wording.
   - `author: "QAAT"` (current "U-Panel").
   - `createdAt`, `expiresAt` = +14 days.
   - `sendPush: true`, `audience: "student"`, `targetStudentId`, `targetListId`, `sessionId`, `kind: "missedSession"`.
4. Enqueue push via `maybe_enqueue_notice_push` (L111–118).

QAAT: implement as outbox topic `missed_session_notice` fired from Go record-write path when `present=false` transition detected (compare previous value on update).

---

## 5. Client-side notice behavior

### 5.1 In-app list (`notices_screen.dart`)

- 60s auto-refresh; create entry (role-gated); push toggle; copy session code; unseen badge integration.
- Audience filtering client-side (`notices_repository.dart`): show notices where audience matches current user (all / their lists / their uid / kiu_admins) and within effective/live windows.
- 7-day disk cache (`notices_disk_cache.dart`) for offline list.

### 5.2 Create flow (`create_notice_screen.dart` + `notice_create_flow.dart`)

- Audience picker scoped by role: lecturer → assigned/created lists only; QA/admin → all lists; single student only for server-generated missed (manual create may allow targeting).
- Title, body, "Valid for" schedule (sets `scheduledFor`).
- Push toggle default on.
- Role-scoped validation in `notices_repository.dart` (mirror server rules in QAAT server validation).

### 5.3 Push receipt

- `push_controller.dart`: OneSignal on mobile; desktop/web fall back to polling (`desktop_notice_watch.dart`).
- `push_tag_builder.dart`: registers `stu_`, `lec_`, `list_`, `kiu_admins`, `all_notices` tags on login / list membership changes.
- Tapping a `sessionCode` push can trigger auto check-in flow ([06](06-attendance-module.md) §8.3).

### 5.4 Local notifications (complement to push)

- Lesson-start reminders (lecturer).
- QA overdue reminders at lesson+1:30 (`attendance_lesson_notification_scheduler.dart`).
- Pending-offline 24h reminder (`pending_offline_notification_scheduler.dart`).
- Workmanager periodic maintenance; reboot re-apply; stable ids (`notification_ids.dart`).

---

## 6. QAAT implementation checklist (notices & push)

- [ ] `notices` table + CRUD API with role-scoped create (lecturer limited audiences).
- [ ] Write hook → outbox `notice_push` when send_push live.
- [ ] 60s scheduled-notice publisher worker.
- [ ] OneSignal worker: tags filters, copy defaults, 500-char clamp, 15s timeout, `pushSentAt` stamp.
- [ ] Missed-session outbox on record `present=false` transition; deterministic id; 14d expiry.
- [ ] Push-device registration validates tag grammar; optional role-tag consistency.
- [ ] Flutter: notices list + create + badge + cache + push controller + tag builder + local notification schedulers.
- [ ] Tests: enqueue idempotency, scheduled publish, missed-session dedupe, copy defaults (port `backend/notices/tests.py`, `test_notice_push_enqueue.py`, `test_missed_session_notice.py`).
