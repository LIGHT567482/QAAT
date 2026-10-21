# 12 — Offline & Sync

QAAT is **offline-first** on mobile. Lecturers can create lists/sessions and students can check in with no connectivity; work is persisted in Hive queues and drained when online. This document specifies every queue, the drain order, retention, and conflict rules.

**Current sources:** `lib/features/attendance/data/*` (queues + sync workers), `lib/core/storage/attendance_local_queues.dart`, `lib/core/offline/pending_offline_coordinator.dart`, `attendance_offline_sync.dart`, `offline_capture_trust.dart`, `pending_retention.dart`.

---

## 1. Storage

- **Hive box:** current `u_panel_attendance_queues`; QAAT: `qaat_attendance_queues` (with one-time read-fallback migration from old box if upgrading in place).
- **Fallback:** SharedPreferences (degraded mode).
- **Keys** (`attendance_local_queues.dart`):

| Key | Queue |
|---|---|
| `pending_attendance_check_ins` | Student check-ins |
| `pending_attendance_session_codes` | Session-code claims / validation |
| `pending_attendance_session_sync_summary` | Sync bookkeeping |
| `pending_attendance_session_creates` | Lecturer offline session creates |
| `pending_attendance_list_creates` | Lecturer offline list creates |
| `pending_campus_presence` | Staff campus check-in/out events |
| `cached_campus_geofence_v1` | Cached campus geofence |

- **Corrupt recovery:** on boot, sanitize box (skip bad rows); `fromJson` returns null on parse failure → silently dropped (`pending_check_in_queue.dart` L216–247).
- **Serialized writes:** `withSerializedWrites` (L180–194) chains read-modify-write through a `Completer` tail so enqueue/drain cannot clobber each other.

---

## 2. Queues in detail

### 2.1 Check-in queue (`pending_check_in_queue.dart`, 332 lines)

`PendingCheckInEntry`:

| Field | Notes |
|---|---|
| `id` | **`{sessionId}_{studentId}`** (stable dedupe key) |
| `sessionId`, `studentId`, `listId`, `course` | |
| `capturedAt` | original capture time (used for offline re-validation) |
| `pendingSince` | defaults to capturedAt |
| `latitude`, `longitude` | |
| `deviceId` | |
| `sessionCodeRaw` | optional |
| `status` | `queued` \| `approved` |
| `uploadedAt` | upload evidence that "survives Firestore read denials" (L289) |

Operations:

- `enqueue()` (L249–269): **upsert by `entry.id`**; preserves existing `uploadedAt` if new row lacks one.
- `containsRecordId`, `removeById`, `removeBySessionId`, `markUploaded` (L289–308, idempotent), `markApproved` (L310–327, keeps row for retention), `clear`.
- **Retention:** `PendingRetention.checkInRetention` = **7 days** (`pending_retention.dart` L6–18).

### 2.2 Session-code queue (`pending_session_code_queue.dart`, 487 lines)

Statuses: `queued` | `approved` | `needsRegistration` | `invalidOrExpired` | `deviceBlocked` | `uploadFailed` (L15–24). Entry id = `"${CODE}_${REG}"`. Serialized writes (L250–262); enqueue applies device-registration lock + local device block (L312–347). Sync logic: `pending_session_code_sync.dart` (1412 lines) — `_tryProcess` L1118–1396 (local-session hint → wait up to 7 days for lecturer session upload L1208–1211); enroll outcomes L1332–1359 (`needsRegistration` / `deviceBlocked` / course resolution).

### 2.3 Session-create queue (`pending_session_create_queue.dart`, 164 lines) + sync (383 lines)

- Storage key `pending_attendance_session_creates`; **max 50 entries** (`_maxEntries` L10; trim keeps newest L137–145); enqueue dedupes by `sessionId` (L147–156) and drains immediately when online.
- Sync (`pending_session_create_sync.dart`): `drainUrgent()`; non-urgent probes reachability (3s). Per-session backoff `_scheduleRetryAfterFailure` = `15 * failures` seconds clamped 15–120 (L36–41); list-not-yet-published defers 8s (urgent) / 30s (L112–117). Upload flow per entry (L103–228): ensure list published (`_ensureListPublished` L251–277) → if doc already exists server-side, adopt + publish RTD → else write session doc with `locationMetadataPending: !metadataReady && !remoteLearning` (L172–186) → **confirm doc exists on server** (L188–203; keeps entry + backoff if not) → publish RTD (`SessionRtdSync.publishRunningSession` L338–366) → remove from queue → `_markListActive` (L298–334) → `_publishNoticeIfNeeded` (L368–382, skipped for remoteLearning). Parallelism 4 (mobile) / 2 (web); timeouts 10s/18s upload, 6s/10s probe (L28–34). On success: notify store, prefetch sessions for pending codes, `PendingSessionCodeSync.drainUrgent()` (L242–248).

### 2.4 List-create queue

`pending_list_create_queue.dart` / `_sync.dart`: same pattern as session creates (ensure-before-dequeue, backoff).

### 2.5 Campus presence queue

`pending_campus_presence_queue.dart` / `_sync.dart`: staff check-in/out events; drained after check-ins in the full chain.

### 2.6 Claim upload (`pending_session_code_claim_upload.dart`)

Fallback when document/RTD upload is permission-denied: claim doc id from `{CODE}_{REGNO}` (L35); used by check-in fallback path ([06](06-attendance-module.md) §9.13).

---

## 3. Drain orchestrator (`attendance_offline_sync.dart`, 679 lines)

### 3.1 Locks & entry points

- Full-drain lock `_drainTail` (L56); urgent lock `_urgentDrainTail` (L60) so hot-path check-in uploads never queue behind a full drain; full drain re-runs while `_drainAgain` (L168–171).
- `drainAllInOrder()` (L66–93), `drainSessionValidationFirst()`/`drainCheckInsPromptly()` (L96–98, 140–142), `drainUrgentUploadsOnly()` (L102–137, **45s** time budget), `drainCheckInUploadsOnly()` (L146–158).

### 3.2 Order (L209–254)

1. List creates
2. Session creates (urgent)
3. Session codes (urgent)
4. Purge expired
5. `syncUnuploadedSignIns`
6. Session-code retry loop (`_drainSessionCodesWithRetry` L257–284, 3–4 passes with backoff)
7. `_drainCheckInsWithoutReload`
8. Store refresh (`loadAll`)
- Plus campus presence in the full chain; `correctMetadataMatchedAbsentRollForSignedInLists` during drains (L248–253).

### 3.3 Purge (`purgeExpiredPendingOnly`, L346–406)

- Rows older than **7 days** dropped.
- Expired **unverified** check-ins converted to **absent** via `_markUnverifiedCheckInAbsent` (L655–678: remove local present row, add `present:false` record).
- Expired session-code rows: local side effects discarded (`PendingSessionCodeSync.discardLocalAttendanceSideEffects`).

### 3.4 Check-in replay (`_drainCheckInsWithoutReload`, L427–653)

1. Purge expired; drop sessions unknown locally after expiry.
2. Device-block check per entry (`isDeviceBlockedForStudentSession`) → drop + `clearLocalUnverifiedPresentForCheckIn`.
3. Canonicalize student id (`canonicalStudentIdForUpload`) — rebuild entry with canonical record id if changed.
4. If `AttendanceStore.hasCheckedIn` + verified + accepted on server → mark `approved`, count as duplicate drop.
5. If already has `uploadedAt` → re-evaluate approval only.
6. Else re-submit via `submitStudentCheckInWithOfflineSupport(...)`; switch on outcome (L547–622):
   - `success`/`duplicate` → check approval; approved rows get `quickVerifyStudentCheckIn` (L625–634).
   - `submittedPendingVerification` → if `pendingCheckInHasServerEvidence` → `markUploaded`.
   - `queuedOffline` → keep.
   - `sessionMismatch`/`rejectedVerification` → if evidence matches session (`pendingCheckInMatchesSessionForCorrection`) **locally upgrade row to verified present** (L593–617) and keep queue row.
   - `deviceBlocked` → drop.
7. On exception: **leave queue intact** for next drain (L647–652).

`countPendingWork()` (L412–425) powers the "N pending items" badge (L40–43).

### 3.5 Coordinator (`core/offline/pending_offline_coordinator.dart`)

5s tick, 150ms debounce, 50s background timeout, lifecycle-aware (pause on background, resume on foreground/connectivity).

### 3.6 Capture-order rule (critical invariant)

When a student checks in online or offline, the client **must** apply the local present row + upsert the persistent queue entry **before or around** the network upload (repo L9072–9098, 9278–9290). This ensures an app kill mid-flight still leaves durable evidence. Documented in `docs/ATTENDANCE_BLUEPRINT.md` Part 5; QAAT Flutter port must not reorder this.

---

## 4. Offline trust rules (`offline_capture_trust.dart`)

- `offlineQueuedCheckInTrustsPresent`: entry trusts Present only if `entry.listId == session.listId` when set (L8–17) — list-scoped.
- Blocking rules for roll finalize (L50–62): pending check-ins / blocking session-code rows prevent writing absents ([06](06-attendance-module.md) §9.20).

---

## 5. Connectivity detection

`core/connectivity/app_connectivity.dart`: connectivity_plus + API ping; **2 failed probes → offline banner**. `online_first_persist.dart`: persistOnline-then-offline fallback pattern (try online write, fall back to queue on failure).

Lecturer offline session create: `createSession` enqueues when offline (repo L6471–6480). Student check-in: `submitStudentCheckInWithOfflineSupport` returns `queuedOffline` (L9362–9373).

---

## 6. Device identity & anti-proxy (offline-aware)

- `core/device/device_identity.dart`: stable install id → one present per session per device ([06](06-attendance-module.md) §Gate 5).
- `device_session_usage_store.dart`: shared-phone proxy block after sign-out.
- Offline drain device-block check drops queued entries (sync L427–653 step 2).

---

## 7. QAAT implementation checklist (offline)

- [ ] Hive box `qaat_attendance_queues` + corrupt recovery + serialized writes + SharedPreferences fallback.
- [ ] All six queues: check-ins, session codes, session creates, list creates, campus presence, claims (with max-50 trims, upsert-by-id, retention).
- [ ] Drain orchestrator with full vs urgent locks; exact order in §3.2; 45s urgent budget.
- [ ] 7-day purge + unverified→absent conversion.
- [ ] Capture-order rule in check-in submit path.
- [ ] Offline trust list-scoping + blocking rules for finalize.
- [ ] Connectivity: 2-probe offline detection; online-first persist fallback.
- [ ] Device identity + proxy block + drain-time device checks.
- [ ] Coordinator (tick/debounce/background timeout).
- [ ] UI: pending-sessions screen, offline-queue location screen, pending-work badge, offline banner.
- [ ] Tests: queue upsert/dedupe, purge/absent conversion, drain order, capture-order (app-kill simulation), device-block drop, list-scoped trust.

**Server note:** offline replay hits the same `/api/attendance/check-in-attempts` endpoint with stored `capturedAt` — server skew rules ([06](06-attendance-module.md) Gate 4) make this safe. No separate offline API needed.
