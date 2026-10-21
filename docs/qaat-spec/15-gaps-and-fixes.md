# 15 — Gaps & Fixes

Known defects, dead code, and security gaps in the current django-U-Panel implementation. Each item is a **QAAT fix requirement** (or explicit product decision). Use this as the QAAT backlog of "must not ship these bugs."

Severity: **S1** = security/data-integrity, **S2** = correctness/UX, **S3** = maintainability.

---

## 1. No server-side authorization on document router — **S1**

**Current:** `backend/documents/views.py` `DocumentRouterView` uses only `IsAuthenticated`. Any logged-in student can read/modify/delete **any** collection — other students' records, notices, `campus/presence`, admin projections. Role checks exist only in the Flutter client (`user_role.dart`) and Django admin.

**QAAT fix:** enforce the permission matrix in [05 — Auth & Roles](05-auth-and-roles.md) §3 inside the Go API for every collection operation. Reject with 403. Whitelist collections ([04](04-backend-api.md) §3.4) — reject unknown names instead of creating arbitrary collections.

**Tests:** student cannot write another `studentId`'s attempt; student cannot write `campus/presence`; lecturer cannot edit another lecturer's list without QA role; unauthenticated → 401.

---

## 2. Unreachable legacy routes & dead views — **S3**

**Current:**

- `backend/attendance/urls.py` (`ConnectivityPingView`) — never included in any URLconf.
- `backend/notices/urls.py` (`NoticeListView`) — never included; clients read `GET /api/notices/` via document router.
- `backend/campus/urls.py` (`GeofenceView`) — never included; geofence lives at `attendance/health` → `campus/geofence`.

**QAAT fix:** do not port these URL modules. Implement health as `/api/health/` (already exists); notices and geofence through the typed API. Delete dormant ORM models `Notice`, `CampusGeofence`, `AdminCampusPresence`, `AttendanceList/Session/Record/CheckInAttempt` unless a typed-table port keeps equivalent fields ([03](03-database.md)).

---

## 3. Dormant attendance ORM + broken finalizer — **S2**

**Current:**

- ORM models `AttendanceList/Session/Record/CheckInAttempt` (`backend/attendance/models.py`) have **no API, no admin, no tests** writing to them; live data is in `ApiDocument`.
- `attendance.finalize_expired_sessions` (every 120s, `settings.py:255-258`) closes **ORM** `AttendanceSession` rows — so **document-store sessions are never auto-finalized server-side**; they rely on lecturer device clock/auto-end (`_maybeAutoEndExpired`).
- `attendance.reconcile_check_in_attempt` is an unfinished TODO stub (L4–18), never enqueued.

**QAAT fix:** implement the 120s (or smarter) finalizer against the **live sessions table/collection**: close sessions where `status='active'` and `endTime < now() - grace`. Do not port the stub. Optionally notify lecturer on auto-close.

---

## 4. Admin `documents_total` metric mislabeled — **S3**

**Current:** `backend/upanel/admin_setup.py:100` counts `accounts/users` but labels it "documents total."

**QAAT fix:** Filament dashboard shows true total documents (or typed row counts) plus per-collection breakdown ([08](08-admin-panel-spec.md) §2.1).

---

## 5. Single token per user; no expiry/refresh — **S2**

**Current:** DRF `authtoken` — one active token; `get_or_create`; logout/password reset deletes it; no TTL. Multi-device logout side effects; stolen token valid forever until reset.

**QAAT fix:** allow multiple tokens (per device); add expiry + refresh token rotation; optional JWT with short access TTL. See [05](05-auth-and-roles.md) §8.

---

## 6. No list pagination / cursor — **S2**

**Current:** document router lists only `limit` (max 500) + offset-free ordering; large collections force client-side slicing; no field projection.

**QAAT fix:** add cursor pagination (`cursor`, `limit`) to Go list endpoints; keep `limit` compatibility. Consider sparse fieldsets for hot paths (check-in attempts).

---

## 7. Notice expiry not enforced server-side — **S3**

**Current:** notices store `expiresAt` (14 days for missed-session) but server never filters/expires them; clients hide expired.

**QAAT fix:** either (a) list endpoints filter `expiresAt > now` by default, and/or (b) periodic job deletes/archives expired notices. Document the choice.

---

## 8. KIU-admin self-assertion — **S2**

**Current:** `kiu_admin_onboarding_screen.dart` lets a user **assert** "I am a KIU administrator" after email verify; client sets role/job title. Trusts client.

**QAAT fix:** route through an approval queue (existing admin grants via Filament) or verified staff list match; never flip `kiu_admin` on client assertion alone. See [05](05-auth-and-roles.md) §4.2.

---

## 9. Server accepts check-ins from students not on roster — **S2** (product decision)

**Current:** adjudication (`check_in.py` Gate 2–7) never verifies the student is on the list's roster/sign-ins; record created with `course='—'`. Client intended-flow requires sign-in, but server is permissive (useful for offline/backfill; also abuse vector for arbitrary studentId).

**QAAT fix options:**

1. **Keep permissive** (parity): document as intentional; rely on device + geofence + lecturer oversight.
2. **Harden:** add optional `requireRoster=true` per session/list; reject with new reason `"student not on roster"`; keep legacy string mapping.

Decide per KIU policy; if hardened, update [06](06-attendance-module.md) gates and client matcher.

---

## 10. Campus presence timezone / local_date_key trust — **S2**

**Current:** events store device-supplied `local_dateKey` (device local date); classifications (on-time ≤08:30 etc.) computed client-side; device timezone/clock can skew rolls.

**QAAT fix:** server stores `captured_at` UTC + optional client tz offset; recompute `local_date_key` and policy buckets server-side in **Africa/Kampala** (or campus-configured tz). Treat client labels as hints only. See [10](10-campus-presence.md) §3.

---

## 11. Hardcoded CSRF trusted origin — **S3**

**Current:** `settings.py` adds hardcoded `https://kiu.orion13.us` to `CSRF_TRUSTED_ORIGINS` alongside env list.

**QAAT fix:** env-only origins; no hardcoded production host in code. Same for any CORS allow-list hardcoding.

---

## 12. Rate limiting only on email flows; cache-dependent — **S3**

**Current:** verification/reset cooldowns via Django cache; degrades to no-op if cache fails. No global API throttling.

**QAAT fix:** Redis-backed token bucket for email flows that **fails closed** (or uses DB) if cache down; add optional per-token request limits on auth + check-in endpoints.

---

## 13. Check-in processing couples client to server prose — **S3**

**Current:** client `check_in_rejection.dart` matches rejection reasons by **substring**, including legacy variants; couples UI copy to server strings (`docs/ATTENDANCE_BLUEPRINT.md` warns this).

**QAAT fix:** add stable `rejectionCode` enum (e.g. `outside_location`, `device_shared`) alongside human `rejectionReason`; client maps codes → copy. Keep exact legacy strings for old queued rows.

---

## 14. No schema validation on document payloads — **S2**

**Current:** router stores arbitrary JSON; typos (`lat` vs `latitude`) silently accepted; type drift (`"false"` vs `false` handled ad hoc in missed-session logic).

**QAAT fix:** typed tables enforce columns + CHECKs ([03](03-database.md)); for the generic `documents` table, optional JSON Schema per whitelisted collection. Normalize `present` to strict boolean at write time.

---

## 15. Session-code uniqueness only client-side — **S2**

**Current:** join-code collision handling is client loops (50/12 attempts) + server `order_by(-updated_at)` tie-break; two devices racing can mint the same active code.

**QAAT fix:** partial unique index `(session_code) WHERE status='active'` (Postgres) + app-level check (SQLite); `createSession` retries on conflict. See [06](06-attendance-module.md) §3.2.

---

## 16. Beat schedule hardcoded in settings — **S3**

**Current:** `CELERY_BEAT_SCHEDULE` in `settings.py`; `django_celery_beat` DatabaseScheduler enabled for extra dynamic entries but primary schedule is code.

**QAAT fix:** Python worker loads intervals from config/env or a `job_schedules` table; document defaults (30s sweep, 60s notices, 120s finalize) in [04](04-backend-api.md) §7.

---

## 17. Email verification not gating sensitive writes — **S2**

**Current:** registration returns token immediately; `email_verified` gates some visibility but **router does not check it** — unverified student can check in / write attempts.

**QAAT fix (recommended):** block check-in attempt creation (and list sign-in) until `email_verified=true`, with clear client UX ("verify email to check in"). Keep login working pre-verify for the verification screen. Product confirmation required.

---

## 18. Client fails open on join-code generation after 50 tries — **S3**

**Current:** `generateUniqueSessionCode()` returns last code after 50 collisions (fails open); online-aware variant fails closed on server query error.

**QAAT fix:** surface error to lecturer ("could not allocate unique code — retry"); or switch to server-minted codes (enhancement) with transactional uniqueness.

---

## 19. `finalize_expired_sessions` vs client auto-end race — **S2**

**Current:** client auto-ends on expiry using device clock; server finalizer targets dead ORM table; students forbidden from pushing `closed` (good). Result: if lecturer device offline, sessions stay `active` indefinitely; late check-ins keep passing Gate 4 (`status=='active'`).

**QAAT fix:** server-side finalizer closes expired active sessions (fix #3); clients observe `status=closed` via watch/poll and update UI. Keep student-side prohibition on closing.

---

## 20. No audit trail on attendance record edits — **S2**

**Current:** records can be flipped present/absent via document router with no log of who/when/why (lecturer marking absent indistinguishable from student write in audit terms).

**QAAT fix:** every record mutation writes actor uid + timestamp + source (`api`/`admin`/`grace_reaper`); Filament activity log ([08](08-admin-panel-spec.md) §6); expose in support UI.

---

## 21. Push tags not validated against role — **S3**

**Current:** `POST /api/push/register/` accepts arbitrary `tags` from client; a student could register `lec_<other>` or `kiu_admins` tags and receive staff pushes.

**QAAT fix:** server derives authoritative tags from user role + list memberships; ignore/reject client-supplied privileged tags; allow only safe subset.

---

## 22. HTML email templates / deep links hardcode old brand — **S3**

**Current:** `email_templates.py` green brand `#177245`, logo assets, `upanel://` return URL, `com.u_panel` package.

**QAAT fix:** rebrand to QAAT as part of rename ([14](14-rename-migration-playbook.md) Phase 2/3); parameterize brand color/logo via env.

---

## 23. SQLite/Postgres behavioral drift risk — **S2**

**Current:** `DATABASE_URL` Postgres in prod; SQLite fallback dev. JSON field filters (`data__key`, GIN indexes) are Postgres-centric; SQLite JSON1 differs; partial index syntax differs.

**QAAT fix:** CI runs the full test suite on **both** engines; document any feature-flagged Postgres-only perf indexes ([03](03-database.md) §8). Avoid Postgres-only SQL in hot paths without SQLite fallback.

---

## 24. No request IDs / structured logs — **S3**

**Current:** Django default logging; hard to trace a check-in across API → Celery → OneSignal.

**QAAT fix:** Go middleware assigns `X-Request-Id`; propagate to outbox jobs and Python workers; Sentry breadcrumbs tie together.

---

## Summary backlog (prioritized)

| Priority | Items |
|---|---|
| **Must fix before QAAT prod (S1)** | #1 server authorization |
| **Must fix for correctness (S2)** | #3 finalizer, #5 tokens, #6 pagination, #8 KIU-admin approval, #10 campus tz, #14 validation, #15 code uniqueness, #17 email-gate, #19 expire race, #20 audit, #23 dual-engine CI |
| **Should fix (S2 cont.) / product** | #9 roster policy, #12 rate limits |
| **Nice to have (S3)** | #2 dead code, #4 metrics, #7 expiry, #11 hardcode, #13 rejection codes, #16 schedule config, #18 fail-open codes, #21 tags, #22 brand, #24 logging |

Every S1/S2 item must have an acceptance test in the QAAT suite; link the test name in the PR that closes the gap.
