# 06 — Attendance Module

The heart of QAAT. This document specifies **all** attendance behavior: data model, code generation, server adjudication gates, client check-in pipeline, session lifecycle, and every "what if" scenario with its resolution.

**Source of truth for current behavior:**

- Server adjudication: `backend/documents/services/check_in.py`
- Missed-session notices: `backend/documents/services/missed_session_notice.py`
- Background jobs: `backend/attendance/tasks.py`
- Client models/codes: `lib/features/attendance/models/attendance_models.dart`
- Client validation: `lib/features/attendance/check_in_validation.dart`
- Client check-in UI: `lib/features/attendance/student_check_in_progress_screen.dart`
- Lecturer session UI: `lib/features/attendance/attendance_screen.dart`
- Roll cells: `lib/features/attendance/roll_cell_status.dart`
- Offline queues: `lib/features/attendance/data/*` (see also [12 — Offline & Sync](12-offline-and-sync.md))

---

## 1. Domain recap

```
attendance/lists ──1:N──▶ attendance/sessions ──1:N──▶ attendance/records
        │                        ▲
        │                        │ adjudicated from
        └──roster/sign-ins──▶ attendance/check-in-attempts
```

- **List** = one scheduled lesson.
- **Session** = one timed geofenced check-in window on a list.
- **Attempt** = raw student submission.
- **Record** = authoritative `{present, verified}` outcome; doc id **`{sessionId}_{studentId}`**.

---

## 2. Data shapes (attendance collections)

### 2.1 List (`attendance/lists/{id}`)

| Field | Type | Notes |
|---|---|---|
| `id` | string | epoch-millis (client-generated) |
| `title`/`name` | string | |
| `room` | string | |
| `time` | string | lesson time label |
| `whoTaught` | string | lecturer display |
| `date` | `YYYY-MM-DD` | |
| `program` | string | day / weekend |
| `courses` | string[] | |
| `year`, `sem` | string/int | |
| `status` | string | list lifecycle |
| `createdBy` | uid | |
| `lecturerUid` | uid, indexed | owner |
| `expectedParticipants` | int? | |
| `lecturerSignCode` | string? | 4–8 chars |
| `lecturerSignedAt` | iso? | |
| `courseUnitName` | string? | |

### 2.2 Session (`attendance/sessions/{id}`)

| Field | Type | Notes |
|---|---|---|
| `id` | string | epoch-millis |
| `listId` | string | |
| `sessionCode` | string | normalized uppercase `A12B` |
| `startTime`, `endTime` | iso timestamptz | |
| `status` | `active` \| `closed` | |
| `latitude`, `longitude` | double | geofence centre |
| `radiusMeters` | int | 100/200/500/1500 |
| `remoteLearning` | bool | skip geofence |
| `locationMetadataPending` | bool | GPS failed at creation → skip geofence |
| `rollDiscarded` | bool | "end without saving" |
| `sessionGpsAccuracyMeters` | double? | lecturer accuracy at start |
| `createdBy` | uid | |
| `finalized` | bool | |

### 2.3 Attempt (`attendance/check-in-attempts/{id}`)

| Field | Type | Notes |
|---|---|---|
| `id` | string | `{sessionId}_{studentId}` or UUID |
| `sessionId` | string? | filled after linking |
| `sessionCodeRaw` | string? | typed code before link |
| `listId` | string? | |
| `studentId` | string? | |
| `deviceId` | string? | stable install id |
| `course` | string? | |
| `status` | `pending`\|`accepted`\|`rejected` | |
| `rejectionReason` | string? | exact strings §6 |
| `awaitingSession` | bool | lecturer hadn't started |
| `capturedAt` | iso? | student-device time |
| `clientSubmittedAt` | iso? | upload time (skew detect) |
| `latitude`, `longitude` | double? | |
| `gpsAccuracyMeters` | double? | |

### 2.4 Record (`attendance/records/{sessionId}_{studentId}`)

| Field | Type | Notes |
|---|---|---|
| `sessionId`, `studentId` | string | composite PK |
| `listId` | string | |
| `course` | string | default `—` |
| `present` | bool | |
| `verified` | bool | |
| `timestamp` | iso | |
| `latitude`, `longitude` | double? | |
| `deviceId` | string? | |

---

## 3. Codes generated

All code generators live client-side (`lib/features/attendance/models/attendance_models.dart` and `attendance_repository.dart`). The server **never generates join codes** — it only matches them.

### 3.1 Session join code (student types this)

**Primary format:** `A12B` — one letter, two digits, one letter.

```dart
// attendance_models.dart:414-430
const kSessionJoinCodeExample = 'A12B';
final RegExp kSessionJoinCodePrimaryPattern = RegExp(r'^[A-Z]\d{2}[A-Z]$');

String generateSessionCode() {
  final rnd = Random();
  String letter() => String.fromCharCode(65 + rnd.nextInt(26));
  final digits = rnd.nextInt(100).toString().padLeft(2, '0');
  return '${letter()}$digits${letter()}';
}
```

- Alphabet A–Z, digits 00–99 → **26 × 100 × 26 = 67,600** possible codes.
- Non-cryptographic `dart:math Random()` (QAAT recommendation: `Random.secure()` is unnecessary here since collision handling exists; keep parity unless codes become security-sensitive).

**Legacy formats still accepted** on input (`isValidJoinCodeFormat`, models L438–443):

- `###` (3 digits) — oldest
- `####` (4 digits)
- `L###` (letter + 3 digits)

**Normalization** (`normalizeSessionCodeInput`, L432–435): trim → remove all whitespace → uppercase.

**QAAT must accept all legacy formats** for backward compatibility with old links/notices; new sessions always mint `A12B`.

### 3.2 Join-code uniqueness & collision handling

Client-side, in `attendance_repository.dart`:

| Function | Lines | Behavior |
|---|---|---|
| `generateUniqueSessionCode()` | 5866–5878 | Loop ≤ **50** attempts: generate → reject if any **local active** session has same code (case-insensitive). **Fails open**: returns last code after 50 tries. |
| `generateUniqueSessionCodeOnlineAware()` | 5880–5897 | Same, but also skips codes active **on server** (`_joinCodeActiveOnServer`). Falls back to local-only on query error. |
| `_joinCodeActiveOnServer()` | 5899–5908 | Server query; **fails closed** on error (assume clash). |
| `_joinCodeClashesWithOtherSession()` | 5910–5929 | Clash if different-id session with same normalized code is `isOpenForCheckIn` locally, or RTD `fetchActiveByCode` returns others. |
| `ensureJoinCodeForSessionUpload()` | 5931–5975 | ≤ **12** regeneration attempts before session upload; on change, update local store session code + re-notify UI. |

**Server-side link tie-break** when multiple active sessions share a code (race): `_link_session_by_code` (`check_in.py:137-158`) filters `sessionCode__iexact=code` AND `status="active"`, orders by **`-updated_at`** (most recently touched wins), takes `.first()`.

**Client-side tie-break** (`_pickActiveJoinSession` repo L6026–6037, `sessionByCodeOpenForCheckIn` models L884–897): among **open** sessions, pick **latest `startTime`**.

**QAAT hardening (recommended, see [15](15-gaps-and-fixes.md)):** enforce partial unique index on `(session_code) WHERE status='active'` so two active sessions can never share a code; keep the `order_by(-updated_at)` fallback for data imported before the constraint.

### 3.3 Student roster 3-digit code

Per-list short code shown on roll/print (`models.dart:821-832`, `registerStudent` L1450–1453):

- Counter `_codeCounter` starts at **100**.
- Next code = `(_codeCounter % 999) + 1`, zero-padded to **3 digits** (so wraps 999 → 100).
- Uniqueness loop on register (reject if already used on that list).
- Counter restored from max existing code (repo `_updateCodeCounter` L4905–4913; snapshot restore `attendance_local_snapshot.dart` L37, 132–134).

### 3.4 Student initials

`models.dart:450-478`:

- Valid pattern: `^[A-Z]{2,4}$` (2–4 uppercase letters).
- Derived from full name: first + last initial (`deriveStudentInitialsFromName` / `initialsFromFullName`), padded as needed.

### 3.5 Lecturer sign code

`models.dart:115-147`:

- `lecturerSignCode`: normalized **4–8 character** code the lecturer enters on "Sign in → Lecturer" to claim ownership of a list.
- No generator exists in current client — code is **manually set / persisted**; null/empty = not configured.
- `hasLecturerSignCode` / `isLecturerSigned` getters.
- Seed data sets `""` (`seed_demo_attendance_list.py:43`).

**QAAT:** keep manual set; optionally add "generate" button client-side (format `[A-Z0-9]{4,8}`).

### 3.6 Deterministic IDs (idempotency keys)

| ID | Scheme | Where |
|---|---|---|
| Attendance record | **`{sessionId}_{studentId}`** | `attendanceRecordIdForSessionStudent` models L302; server `check_in.py:69,86-102` |
| Missed-session notice | **`missed_{sessionId}_{studentId}`** | `missed_session_notice.py:75-80` |
| Session-code claim doc | `{CODE}_{REGNO}` | `pending_session_code_claim_upload.dart:35`, repo L9085, 9116–9117 |
| Pending check-in queue entry | `{sessionId}_{studentId}` | `pending_check_in_queue.dart` (entry.id) |
| Session / list id | epoch-millis string | `createSession` repo L6400; list id `attendance_screen.dart:3339` |

These ids are load-bearing: **do not change** in QAAT or offline replay and server idempotency break.

---

## 4. Session lifecycle (lecturer)

### 4.1 Start session

UI: `attendance_screen.dart` `_startSession()` L1805–1962; dialog L1971+; repository `createSession()` L6376–6506.

Inputs:

- Duration slider: `[1, 10, 15, 20, 25]` minutes, default **15**.
- Geofence radius options: `[100, 200, 500, 1500]` m, default **1500** (on-campus; `remoteLearning` → radius 0 / skip).
- `remoteLearning` toggle.
- GPS required for on-campus sessions (location resolving panel).

Guards against double-start:

1. Pre-check active session for list (L1810–1827) → snackbar "already has a live session", show its code.
2. Capture `startIntentAt` before async GPS (L1829) to reduce clock drift.
3. Second re-check after GPS resolves (L1881–1898) → "A live session was started while preparing…".
4. Repository `createSession` returns existing active session if one exists (L6387–6398) — "avoids duplicates from double taps or slow GPS".

Session doc fields written (repo L6092–6125 / L6242–6266): `listId`, `sessionCode` (unique), `latitude`, `longitude`, `radiusMeters`, `startTime`, `endTime`, `status:'active'`, `createdBy`, `createdByUid?`, `remoteLearning?`, `locationMetadataPending` (= `!remoteLearning && !isValidCheckInCoordinates(lat,lng)`), `sessionGpsAccuracyMeters?`.

Offline path: enqueue to `PendingSessionCreateQueue` (max **50** entries, dedupe by sessionId), return `syncedToServer: false`; drain via `pending_session_create_sync.dart` (ensure list published → upload session → confirm exists → publish RTD → mark list active → publish notice if applicable).

### 4.2 During session — code display

`_SessionCodeDisplay`:

- Live countdown to `endTime`.
- Copy code to clipboard.
- Manual "End" (confirm dialog).
- **Auto-end on expiry** + roll finalize (`_maybeAutoEndExpired` L2343–2348).
- Publish-to-server for offline-created sessions.

QA can also start sessions for overdue classes (`qa_overdue_attendance_screen.dart`, notice kind `qaStartAttendance`).

### 4.3 End & save roll

`_endSessionAndSaveRoll()` L2350–2375 → confirm dialog text (L2356–2360):

> "The join code will stop working. Roster students who did not check in show as Pending for up to 7 days while queued check-ins sync and verify. After 7 days, anyone still unverified is marked Absent."

Flow: `_closeSessionAndExit` L2308–2341 → `closeSessionAndFinalizeRoll(sessionId)` → `closeSessionInFirestore` (L6973–6977) = local `AttendanceStore.closeSession` (models L912–931 sets `status: closed`) + `_syncSessionClosedToFirestore`.

**Fields written on close** (`_archiveClosedSessionToFirestore` L6925–6948): status flips to `closed`; `endTime` is **not** modified; `finalized:false`; RTD running-session removed (`SessionRtdSync.removeRunningSession`).

**Roll finalize** (`finalizeRollForSession` L7074–7218):

- **Bails** if session `rollDiscarded`, awaiting upload, any pending check-in for the session, or any blocking pending session-code row (L7078–7090; blocking rules `offline_capture_trust.dart` L50–62).
- Builds present set from: trusted pending check-ins, trusted pending session codes, local records (verified **or** unverified present), server records.
- For missing roster students: writes absent row only when `missedBeforeJoin` (session ended before they joined the list) or `studentSessionGraceExpired` (7-day cap or later present on same list — `student_session_grace.dart` L10–27), and not blocked by awaiting claims/unexpired evidence (L7168–7179).

### 4.4 End without saving roll (discard)

`_endSessionWithoutSavingRoll()` L2377–2419 → `closeSessionWithoutSavingRoll()` L7014–7028:

- Delete local records for session, `PendingCheckInQueue.removeBySessionId`, `PendingSessionCodeQueue.removeForSession`.
- Remove session from store, RTD removal, delete Firestore session doc + remote records, `PendingSessionCreateQueue.removeBySessionId`.
- Session is **deleted**, not closed; any surviving copies excluded from stats via `rollDiscarded`/`countsTowardRollStats` (models L229–263).

### 4.5 Students still pending at close

Closing does **not** delete pending check-ins (save path). They remain in queue and keep draining; `finalizeRollForSession` refuses to write absents while pending rows exist (L7081–7084). Non-checked-in roster students show as **Pending** until grace expires (7 days) then **Absent** (`roll_cell_status.dart` L275–287; `purgeExpiredPendingOnly` converts unverified check-ins to absent).

Grace reaping: `finalizeGraceExpiredSessions()` L2746–2751 (called from offline drain); lecturer-only `_finalizeExpiredOpenSessions()` L2716–2736 (skipped for students, L2721 — students must not push `closed` based on local clock).

---

## 5. Server adjudication gates (the engine)

Current: `backend/documents/services/check_in.py` (`maybe_process_check_in`, L26–102). QAAT Go port must implement **exactly** this ordered chain.

Constants:

```python
GEOFENCE_BUFFER_METERS = 25
MAX_GPS_UNCERTAINTY_BUFFER_METERS = 75
CLOCK_SKEW_TOLERANCE = 120          # seconds early grace
CLOCK_DIVERGENCE_LIMIT = 300        # seconds; beyond → use server receipt time
```

### Gate 0 — Idempotency guard (L27–32)

Only process attempts in collection `attendance/check-in-attempts` whose `status` is empty or `"pending"`. Accepted/rejected attempts are skipped.

### Gate 1 — Session linking (L34–44, `_link_session_by_code` L137–158)

If no `sessionId` or `awaitingSession` is true:

1. Take `sessionCodeRaw` (or `sessionCode`), uppercase/normalize.
2. Query sessions: `sessionCode__iexact=code` AND `status="active"`, order `-updated_at`, first.
3. On match: write `sessionId`, `listId`; clear `awaitingSession`.
4. On no match:
   - If `awaitingSession` **or** a raw code was provided → **leave `pending`** (retry later via 30s sweep).
   - Else → reject `"session code not found"` (L42).

### Gate 2 — Student id (L46–49)

`studentId` missing/blank after trim → reject `"missing student id"`.

### Gate 3 — Session exists (L51–54, `_load_session` L161–168)

Load session by `sessionId`; missing → reject `"session does not match"`.

### Gate 4 — Time window (L58, `_within_session_time` L197–241)

```
effective_time =
  if capturedAt missing            → clientSubmittedAt (server receipt proxy)
  elif |clientSubmittedAt − capturedAt| > 300s → clientSubmittedAt (server time wins)
  else                              → capturedAt

early_ok  = effective_time >= startTime − 120s
late_ok   = effective_time <= endTime  OR  session.status == "active"
pass      = early_ok AND late_ok
```

Notes:

- Late check-ins are allowed while session is still `active` even past `endTime` (lecturer hasn't closed).
- Clock-skew defense: if device clock is wildly off (divergence > 300s), server receipt time is authoritative (unspoofable).
- Client offline replay validates against **stored `capturedAt`** (`check_in_validation.dart` `isTimestampWithinSessionBounds` L52–60) — same rules mirror.

Failure → reject `"outside session time"`.

### Gate 5 — Device anti-sharing (L62, `_device_used_by_other_student` L119–134)

Query attendance records for this `sessionId` where `deviceId` equals the attempt's `deviceId` and `present=true` and `studentId !=` this student. If found → reject `"device already used for another student"`.

Blocks one physical phone checking in multiple students.

Client also enforces locally (`isDeviceBlockedForStudentSession`, device identity stores — see [12](12-offline-and-sync.md) §6).

### Gate 6 — Geofence (L66, `_within_geofence` L244–273)

```
if session.remoteLearning:            return True   # skip
if session.locationMetadataPending:   return True   # skip (GPS failed at start)
if session.latitude≈0 and longitude≈0: return True  # unset centre → skip

if |studentLat| < 0.001 and |studentLng| < 0.001: return False  # Null Island reject

distance = haversine_meters(student, session_centre)   # R = 6_371_000 m

uncertainty =
  min(0.5 * attempt.gpsAccuracyMeters, 75) +
  min(0.5 * session.sessionGpsAccuracyMeters, 75)

tolerance = session.radiusMeters + 25 + uncertainty

return distance <= tolerance
```

Missing/unparsable student coords → reject `"outside class location"`.

Client mirror: `check_in_validation.dart` L8–29 (`gpsUncertaintyBufferMeters` = 0.5×accuracy capped 75; tolerance = radius + 25 + student buffer + session buffer). On geofence failure the pipeline **retries once** with `forceFresh: true` GPS (`student_check_in_progress_screen.dart` L489–508). Tight radii (≤100m) require fresh high-accuracy fixes (`sessionRequiresHighAccuracyGps` L44–47; fix max-age 90s on-campus vs 8min remote L31–41).

### Gate 7 — Accept & write record (L69–102)

- Set attempt `status="accepted"`, stamp `sessionId`, `listId`, `awaitingSession=false`.
- Record key = `{sessionId}_{studentId}`.
  - If record **already exists** → only flip attempt status (idempotent; do **not** rewrite record).
  - Else `update_or_create` record with `{sessionId, studentId, listId, course, timestamp, latitude, longitude, verified: true, present: true, deviceId}`.

---

## 6. Rejection reasons (exact strings)

Written by `_reject` (L105–109): sets `status="rejected"` + `rejectionReason=<reason>`.

| # | Exact string | Gate | Trigger |
|---|---|---|---|
| 1 | `session code not found` | 1 | No sessionId/awaitingSession and code lookup failed (attempts with raw code are left pending instead) |
| 2 | `missing student id` | 2 | Blank studentId |
| 3 | `session does not match` | 3 | Session doc missing |
| 4 | `outside session time` | 4 | Time window fail |
| 5 | `device already used for another student` | 5 | Device anti-sharing |
| 6 | `outside class location` | 6 | Geofence fail |

**These exact strings are part of the client contract** — the Flutter app categorizes them by substring (`check_in_rejection.dart` L30–74 `categorizeCheckInRejectionReason`) and also matches legacy variants:

- `device already submitted`, `device already signed in`, `another student already used`
- `outside_geofence`, `outside geofence`, `invalid gps`
- `captured outside session time`
- `not signed into`

**QAAT must keep the 6 canonical strings byte-identical**; legacy variants remain in the client matcher for old queued rows.

Client maps each category to a user-facing message (`check_in_rejection.dart` L104–226), e.g.:

- `device already used for another student` → "This device has already been used to check in another student for this session."
- `outside class location` → "You appear to be outside the class location. Move closer to the classroom or ask your lecturer about remote learning."
- `session code not found` → "Session code not found. Ask your lecturer for the current code."

---

## 7. Background jobs (attendance)

Current (`backend/attendance/tasks.py`, schedule `backend/upanel/settings.py:243-259`):

| Task | Schedule | Behavior |
|---|---|---|
| `documents.process_check_in_doc` | on-demand (delay from router) | Fetch attempt doc → `maybe_process_check_in`; retry ≤5× with 4s delay on errors |
| `documents.sweep_awaiting_session_claims` | every **30s** | Reprocess ≤50 oldest pending attempts (last 7 days) with `awaitingSession=true` — links students whose app backgrounded before lecturer started session |
| `attendance.finalize_expired_sessions` | every **120s** | Closes **ORM** `AttendanceSession` past `end_time` (operates on dormant table — QAAT should close document/typed sessions instead, see [15](15-gaps-and-fixes.md) §3) |
| `attendance.reconcile_check_in_attempt` | never scheduled | **Unfinished TODO stub** (L4–18) — do not port |

QAAT Go API adjudicates **synchronously** in the happy path (see [02](02-architecture.md) §4); the 30s sweep remains a Python worker for pending/awaiting attempts. The 120s finalizer becomes a real job closing expired active sessions in the typed table.

---

## 8. Client check-in pipeline (student)

### 8.1 Online happy path

1. Student enters registration number (locked if student-scoped) + session code on `_SignInContent`.
2. Format-validate code (`isValidJoinCodeFormat`); normalize.
3. Unknown-but-well-formed code → confirm dialog (`unknown_session_code_confirm.dart`): "Session code not found" (online) with options "Yes — save this code" (queue up to 7 days) or "No — enter a different code".
4. Acquire GPS (geolocator; reuse last fix ≤5 min old for check-in window).
5. Local pre-validation: time window + haversine geofence (`check_in_validation.dart`).
6. Navigate `student_check_in_progress_screen.dart` with staged progress copy:
   - "Checking session time…"
   - "Confirming your location…"
   - "Verifying you are at class…"
   - "Saving your attendance…"
7. `submitStudentCheckInWithOfflineSupport` (repo L9005–9036):
   - Apply **local present row** + upsert `PendingCheckInQueue` **before/around** RTD upload (capture-order rule).
   - Upload via RTD (`CheckInRtdAttemptPublish.uploadPending` L7451–7475, doc id `sessionId_studentId`); immediate retry after 80ms on failure.
   - Wait ≤1.1s (online) / 300ms for quick verify → outcomes:
     - `success`/`duplicate` → green "Attendance recorded"
     - `submittedPendingVerification` → amber "submitted" card (UI waits up to 8s for server confirm before showing amber instead of green, screen L648–678)
     - `queuedOffline` → "offline recorded" card (screen L705–713)
     - `sessionMismatch`/`rejectedVerification`/`deviceBlocked` → error handling (see §9 what-ifs)
8. Result + Done/Back; 20s busy countdown.

Permission-denied uploads fall back to session-code **claim** channel (`PendingSessionCodeClaimUpload` L9225–9290).

### 8.2 Offline path

1. Same local validation against stored session metadata (if available) using **capture time**.
2. Persist local present row + `PendingCheckInQueue` entry (persistent Hive).
3. Show offline-recorded card.
4. `PendingOfflineCoordinator` / drain on connectivity restore re-submits via same endpoint with stored `capturedAt`/coords (see [12](12-offline-and-sync.md)).

Full offline queue semantics: [12 — Offline & Sync](12-offline-and-sync.md).

### 8.3 Push-triggered auto check-in

`data/session_code_auto_check_in.dart`: a push containing a session code can prefill/auto-submit check-in (20s debounce, result enum). If session no longer active → "Session code $code is no longer active."

---

## 9. What-if scenarios catalog

Each scenario: **Situation → Handling → Where → User-visible outcome**.

### 9.1 Session code not found (online)

- **Handling:** Client shows confirm dialog `unknown_session_code_confirm.dart` L16–135: "We could not find an active session for this code yet." Options: save code (queue claim up to 7 days) or enter different code. Server leaves attempt `pending` if raw code present (sweep retries).
- **Where:** client dialog; server `check_in.py` L38–43; sweep `attendance/tasks.py` L60–96.
- **Outcome:** Student can queue the code; once lecturer starts matching session, sweep links it.

### 9.2 Session code not found (offline)

- **Handling:** Dialog variant: "You are offline and this code is not on this device yet." Same queue-or-retry options. Queued code retried via `PendingSessionCodeSync._tryProcess` (L1118–1396); if a local session hint exists → "waiting for lecturer session to upload (up to 7 days)" (L1208–1211).
- **Outcome:** Offline student not blocked; claim syncs later.

### 9.3 Session already closed/ended

- **Handling:** `isOpenForCheckIn` = `status == "active"` only (models L255–257). Student pipeline gate `student_check_in_progress_screen.dart` L443–452: "This session is no longer active. Ask your lecturer for a new code." Server: after `endTime`, rejects only when `status != "active"` (L236–239). `serverHasOnlyInactiveSessionForCode` (repo L6556–6572) distinguishes expired vs not-found. Pending code whose capture falls inside a **closed** session's window + geofence is still accepted on replay (sync L1243–1254); else `invalidOrExpired` with note "Join code … matches a session that has already ended. Ask your lecturer for the code currently on screen." (L1255–1263).
- **Outcome:** Clear "no longer active" message; old queued evidence inside the window can still count.

### 9.4 Student checks in after `endTime` but before lecturer closes

- **Handling:** Allowed — server `late_ok` is true while `status == "active"` (L236–239). Client same.
- **Outcome:** Late arrival still recorded (roll may show Present; "late" is not a separate state — see [11](11-reports-and-roll.md)).

### 9.5 Duplicate check-in (same student, same session)

- **Handling:** Server: existing `{sessionId}_{studentId}` record → attempt silently accepted, record not rewritten (`check_in.py` L69–77; `update_or_create` L98–102). Relational mirror had `unique_together` (`backend/attendance/models.py` L54–55). Client: `submitStudentCheckInWithOfflineSupport` L9005–9036 returns `StudentOfflineCheckInOutcome.duplicate` ("Attendance was already recorded for this session." — `check_in_rejection.dart` L144–146); pipeline short-circuits earlier for verified present (screen L542–551). Store guard `addAttendanceRecordIfAbsent` (models L977–979) handles concurrent taps.
- **Outcome:** Idempotent; friendly "already recorded" message; no double records.

### 9.6 Student not on any roster/list

- **Handling:** Server check-in does **not** verify roster membership — accepts and writes a record (`course` defaults to `"—"`, `check_in.py` L90). Legacy client reason "not signed into" still mapped (`check_in_rejection.dart` L66, 212 → "Sign into this class list and choose your course before checking in."). Pending-code path enrolls lazily via `ensureStudentEnrolledOnList` outcomes (sync L1332–1359): `needsRegistration` ("Student not on roster yet." / "This class list has no courses…" / "Open Attendance, enter your session code, and choose a course to join this list."), `deviceBlocked`. Course resolution `resolveCourseForStudentCheckIn` (`check_in_validation.dart` L236–245): roster course → first list course → `'—'`.
- **Outcome:** Intended flow requires sign-in first; server is permissive (records still created) — QAAT may optionally harden with roster check (product decision; see [15](15-gaps-and-fixes.md) §9).

### 9.7 GPS disabled / location permission denied

- **Handling:** Client `student_check_in_progress_screen.dart` L291–297, 323–329, 389–395: `_locationServiceDisabled=true`, UI phase `error`; `location_resolving_panel.dart` L32–44 offers "Turn on location". Remote-learning sessions skip hard requirement (5s best-effort GPS L270–289). Server: missing/Null-Island coords → reject `"outside class location"` (`abs(lat)<0.001 && abs(lng)<0.001` → False, L259–260).
- **Outcome:** Student told to enable location; cannot fake Null Island coordinates.

### 9.8 Low GPS accuracy

- **Handling:** Buffer `gpsUncertaintyBufferMeters = 0.5 × accuracy`, cap **75m** (`check_in_validation.dart` L8–17); tolerance = radius + 25 + student buffer + session buffer (L20–29). Server mirrors exactly (`check_in.py` L16–23, L261–273). Tight radii (≤100m) demand fresh high-accuracy fixes (`sessionRequiresHighAccuracyGps` L44–47; max-age 90s vs 8min remote L31–41). On geofence failure, pipeline **retries once** with `forceFresh: true` (screen L489–508).
- **Outcome:** Poor accuracy near the edge can still pass within buffered tolerance; fresh-fix retry rescues stale fixes.

### 9.9 Remote-learning session

- **Handling:** Session flag `remoteLearning` (models L223–224): no radius check (`sessionSkipsLocationCheck` validation L96–100; server `check_in.py` L245–246 returns True), no push notice for session start, `radiusMeters` 0 in UI, snackbar tells lecturer to share code manually.
- **Outcome:** Students check in from anywhere; geofence skipped.

### 9.10 `locationMetadataPending` (lecturer GPS failed at start)

- **Handling:** Set when lecturer GPS centre invalid at creation (repo L6416–6417) or geofence not configured on upload (`activeSessionToFirestoreMapForSync` L6116–6118; create-queue sync L182, 209). Effect: `isSessionGeofenceConfigured` false → `sessionSkipsLocationCheck` true → location check skipped client and server (`check_in.py` L247–248). Roll treats such sessions' metadata as incomplete → cells **Pending** (`roll_cell_status.dart` L16–20, 93–97, 261–264).
- **Outcome:** Check-ins still accepted (no geofence to enforce); roll stays Pending until metadata fixed — QAAT should surface a "fix geofence" action to the lecturer (recommended enhancement).

### 9.11 Clock skew (device vs server)

- **Handling:** Server `_within_session_time` (L197–241): uses `capturedAt`, but if `|clientSubmittedAt − capturedAt| > 300s` → uses server receipt time; no `capturedAt` → receipt time; 2-min early grace; late only rejects when `effective > endTime` AND status not `active`. Client offline replay validates against **capture time** (`isTimestampWithinSessionBounds` L52–60; `_validationTimestampForPendingCode` = `entry.capturedAt`, sync L266–269); `startIntentAt` reduces start-side drift; students never push `closed` based on local clock (repo L2717–2721).
- **Outcome:** Wildly wrong device clocks cannot fabricate attendance outside the true window; minor skew tolerated.

### 9.12 App killed mid check-in

- **Handling:** Capture-order: local present row + persistent `PendingCheckInQueue` upsert **before/around** RTD upload (repo L9072–9098, 9278–9290); queue keyed upsert by `sessionId_studentId`; `uploadedAt` cached (queue L289). On next launch/drain `_drainCheckInsWithoutReload` resumes; `prepareOfflineCheckInDrain` recovers unqueued local present rows (repo L7416–7418). Retention **7 days**, then unverified converted to **absent** (`_markUnverifiedCheckInAbsent` L655–678).
- **Outcome:** No lost check-ins; resume-on-launch; 7-day safety net then honest absent.

### 9.13 Network failure mid POST

- **Handling:** Upload via RTD; failure → one immediate retry after 80ms (L9205–9224), then `_applyLocalPresentCheckInRow` + `_enqueuePendingCheckInRow` → `queuedOffline` (L9362–9373). UI shows offline-recorded card (screen L705–713). Success path waits ≤1.1s (online) / 300ms for quick verify else `submittedPendingVerification` (L9305–9359); UI waits up to **8s** for server confirm before amber "submitted" card (screen L648–678). Permission-denied uploads fall back to claim channel (L9225–9290).
- **Outcome:** Student always gets feedback; queued rows retried by drain.

### 9.14 Session code typed wrong

- **Handling:** Format validated before lookup (`isValidJoinCodeFormat` L438–443); normalization strips spaces/case. Unknown-but-well-formed → confirm dialog (§9.1). Code matching only an ended session → `invalidOrExpired` note (§9.3). Roll ignores `invalidOrExpired` entries (`roll_cell_status.dart` L132). Collision at generation prevented (§3.2); race regeneration ≤12× (`ensureJoinCodeForSessionUpload`).
- **Outcome:** Typos caught; legacy formats accepted; no accidental collision with another live session in normal operation.

### 9.15 Multiple active sessions share the same code (race)

- **Handling:** Client `_pickActiveJoinSession` / `sessionByCodeOpenForCheckIn` → **latest `startTime`** among open sessions (models L885–897; repo L6026–6037). Server `_link_session_by_code` → `order_by("-updated_at").first()` among `status="active"` (L141–149). RTD+Firestore merge dedupes by session id (`_fetchJoinCodeSessionsFromServer` L5977–6024). QAAT hardening: partial unique index (§3.2).
- **Outcome:** Deterministic pick; ideally impossible after QAAT constraint.

### 9.16 Lecturer starts session twice (double tap / slow GPS)

- **Handling:** Four guards (§4.1): UI pre-check, UI post-GPS re-check, repository returns existing active session, code uniqueness.
- **Outcome:** Only one live session per list; snackbar shows existing code instead of creating a second.

### 9.17 Student switches between lists / courses

- **Handling:** Roster sign-in is per list: `SignInRecord` (models L499–521, `listId` + `course`); `hasStudentSignedIntoList`, `courseForStudentOnList` used everywhere. Check-in carries `listIdOverride` (screen L583; sync L1385) and explicit course (`selectedCourse` L563–566). Offline trust is list-scoped: `offlineQueuedCheckInTrustsPresent` requires `entry.listId == session.listId` when set (`offline_capture_trust.dart` L8–17). Pending codes for a list without courses / without chosen course → `needsRegistration` with distinct notes (sync L1339–1350). Enrolling on another list later triggers `_backfillPriorSessionsAfterPresentResolved` (repo L9322–9325) and `correctMetadataMatchedAbsentRollForSignedInLists` during drains (offline sync L248–253).
- **Outcome:** Attendance scoped correctly per list/course; late enrollment can backfill.

### 9.18 Lecturer phone offline when starting session

- **Handling:** `createSession` enqueues `PendingSessionCreateQueue` (max 50, dedupe by sessionId) (repo L6471–6480); drain `pending_session_create_sync.dart`: ensure list published first (`_ensureListPublished` L251–277, 8s/30s defer if list unpublished), upload with `locationMetadataPending` flag, **confirm doc exists on server** before dequeue (L188–203), publish RTD, mark list active, publish notice (skipped for remoteLearning). Backoff `_scheduleRetryAfterFailure` = `15 * failures` s clamped 15–120 (L36–41). Parallelism 4 (mobile) / 2 (web); timeouts 10s/18s upload, 6s/10s probe.
- **Outcome:** Session created as soon as connectivity returns; students waiting on the code get it once uploaded; location may be `locationMetadataPending`.

### 9.19 One device, two students (device sharing / proxy)

- **Handling:** Server Gate 5 rejects second student (§Gate 5). Client: stable install id (`core/device/device_identity.dart`) → one present per session per device; `device_session_usage_store.dart` blocks proxy after sign-out; offline drain device-block check drops queued entries (`isDeviceBlockedForStudentSession` → drop + `clearLocalUnverifiedPresentForCheckIn`, sync L427–653). Tests: `backend/documents/tests/test_check_in_device.py`; Flutter side covered in validation tests.
- **Outcome:** Second student on same phone rejected with clear reason; offline attempts also blocked on drain.

### 9.20 Pending check-ins still queued when roll is finalized

- **Handling:** `finalizeRollForSession` **bails out** if any pending check-in for the session exists (L7081–7084) or blocking pending session-code rows (L7078–7090; `offline_capture_trust.dart` L50–62). Students show **Pending** (not Absent) until grace expires. After **7 days** (`PendingRetention.checkInRetention`, `pending_retention.dart` L6–18), `purgeExpiredPendingOnly` (sync L346–406) drops expired rows; expired **unverified** check-ins converted to **absent** via `_markUnverifiedCheckInAbsent` (L655–678: remove local present row, add `present:false` record).
- **Outcome:** No premature absents; 7-day grace; then honest absent marking.

### 9.21 Celery broker down (server processing unavailable)

- **Handling:** Current router `_dispatch_check_in` (`documents/views.py` L15–27): tries Celery `delay`, falls back to **inline synchronous** processing in the request if broker unavailable. QAAT: adjudication is synchronous in Go API by design (no broker dependency for the happy path); outbox jobs (notices/push) retry independently.
- **Outcome:** Check-ins never fail solely because workers are down.

### 9.22 "End without saving roll" (discard)

- **Handling:** §4.4 — session deleted (not closed); local + remote records deleted; queues for that session purged; `rollDiscarded` flag excludes any surviving copies from stats (models L229–263). Roll cells for discarded sessions → null (`roll_cell_status.dart` L271, 275).
- **Outcome:** Mistaken session fully retracted; no ghost data in percentages.

### 9.23 Conflicting local vs server record (merge)

- **Handling:** `_mergeRollRecord` (`roll_cell_status.dart` L328–338): **verified present > unverified present > absent**; newest timestamp wins between two absents. Offline-trusted present with a conflicting absent record counts as present for percentage (L393–405). Server authoritative for `verified=true`.
- **Outcome:** Verified server truth beats optimistic local state; local unverified still shows Present until corrected.

### 9.24 Student joins the list *after* the session ended (`missedBeforeJoin`)

- **Handling:** `finalizeRollForSession` writes absent for missing roster students when `missedBeforeJoin` (session ended before their earliest list sign-in) (L7168–7179). Roll cell: `missedBeforeJoin` → **Absent** (`roll_cell_status.dart` L277). Client copy: "Missed — session ended before you joined this list" (`student_class_attendance_detail_screen.dart`).
- **Outcome:** Backdated honesty: can't check in to a lesson you weren't enrolled for.

### 9.25 Roster code collision after wrap (999 → 100)

- **Handling:** Uniqueness loop on `registerStudent` (models L1450–1453); counter restored from max existing code so two students on one list never share a 3-digit code within that list.
- **Outcome:** Per-list codes unique; display-only (not a security boundary).

### 9.26 Session upload fails / doc never appears on server

- **Handling:** `pending_session_create_sync.dart` L188–203: after write, **confirm the doc exists on server** before dequeuing; if not, keep entry + backoff. Students' pending codes wait (up to 7 days) for lecturer session to upload (§9.2).
- **Outcome:** No false "session started" state; student claims wait safely.

### 9.27 Attempt references session that vanished (deleted mid-flight)

- **Handling:** Server Gate 3 rejects `"session does not match"` if session doc missing (`check_in.py` L51–54). Client drain drops sessions unknown locally after expiry (sync L427–653 step 1).
- **Outcome:** Clean rejection; stale queue rows purged.

### 9.28 QA starts session on behalf of overdue lecturer

- **Handling:** QA overdue screen (`qa_overdue_attendance_screen.dart`) lists classes with no attendance 1h30m after lesson time; QA can start session (notice kind `qaStartAttendance`). Server accepts attempts against that session like any other (createdBy = QA uid).
- **Outcome:** Coverage when lecturer is absent; audit trail shows QA as creator.

---

## 10. Constants quick-reference

| Constant | Value | Source |
|---|---|---|
| `GEOFENCE_BUFFER_METERS` | 25 | `check_in.py:16` |
| `MAX_GPS_UNCERTAINTY_BUFFER_METERS` | 75 | `check_in.py:17` |
| `CLOCK_SKEW_TOLERANCE` (early grace) | 120s | `check_in.py:224` |
| Clock divergence limit | 300s | `check_in.py:215-221` |
| Join code space | 67,600 (A12B) | `attendance_models.dart:424-430` |
| Join code uniqueness loop | 50 (local), 12 (pre-upload regen) | repo L5866, L5931 |
| Session duration options | 1/10/15/20/25 min (default 15) | `attendance_screen.dart:1601` |
| Radius options | 100/200/500/1500 m (default 1500) | `attendance_screen.dart:1602` |
| Check-in grace (unverified) | 7 days | `pending_retention.dart:6-18` |
| Roster code range | 100–999 | `attendance_models.dart:821-832` |
| Awaiting-session sweep | 30s, ≤50/batch, 7-day cutoff | `attendance/tasks.py:60-96` |
| Session finalize sweep | 120s (ORM; QAAT: typed sessions) | `settings.py:255-258` |
| Student UI wait for server confirm | 8s (amber vs green) | `student_check_in_progress_screen.dart:648-678` |
| GPS fix max-age (check-in reuse) | 5 min | `location_permission.dart` / priming |
| Fresh-fix retry on geofence fail | 1× `forceFresh` | screen L489–508 |

---

## 11. QAAT implementation checklist (attendance)

- [ ] Typed tables / documents for lists, sessions, attempts, records (see [03](03-database.md))
- [ ] Join-code generator + normalizer + legacy acceptance (client)
- [ ] Partial unique index active session codes (server) + keep `order_by(-updated_at)` fallback
- [ ] Synchronous Go adjudication implementing Gates 0–7 exactly
- [ ] Exact 6 rejection strings + client substring matcher
- [ ] 30s awaiting-session sweep (Python worker)
- [ ] 120s expired-session finalizer operating on **live** sessions (fix dormant-ORM bug)
- [ ] Missed-session notice outbox on `present=false`
- [ ] Client capture-order upload + Hive queue + 7-day retention → absent conversion
- [ ] Session lifecycle UI: start guards, countdown, end-save vs discard
- [ ] Roll finalize refusing while pending; grace reaping
- [ ] Tests: geofence, device, skew, duplicate, sweep, discard (port current suites)
- [ ] Feature-parity verification against Flutter `test/` attendance tests
