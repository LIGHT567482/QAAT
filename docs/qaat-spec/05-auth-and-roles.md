# 05 — Auth & Roles

## 1. Roles

Five roles (current `backend/accounts/models.py` `User.Role`, client `lib/core/auth/user_role.dart`):

| Role | Server value | Who gets it | How |
|---|---|---|---|
| Student | `student` | Everyone at registration | `POST /api/auth/register/` always creates `role=student` |
| Lecturer | `lecturer` | Teaching staff | Staff registration (`kiu_staff_register_screen.dart`) or QA-created staff account (`register_staff_screen.dart`) |
| QA staff | `qa_staff` | Quality assurance | QA/admin grants via Filament/Django admin or staff hub |
| Administrator | `administrator` | System admins | Grant via existing admin (`register_administrator_screen.dart`) |
| KIU admin | `kiu_admin` | Senior KIU admins | Grant + onboarding (`kiu_admin_onboarding_screen.dart`) |

**Roles are server-derived, never user-picked at runtime.** Client resolves role flags from `GET /api/auth/me/` and mirror docs (`accounts/admins`, `accounts/lecturers`).

Derived flags:

- `is_administrator` = role ∈ {administrator, qa_staff, kiu_admin}
- `is_lecturer` = role ∈ {lecturer} (KIU admins also mirrored into lecturers collection for attendance powers)
- `hasStaffOperationalAccess` (client) = qa_staff | administrator
- `hasLecturerAttendanceAccess` (client) = lecturer | kiu_admin

---

## 2. Login identifier resolution

Current: `backend/accounts/services/login_identifier.py`.

Resolution order for `POST /api/auth/login/` `{login, password}` (login = email OR reg no OR staff number):

1. **Email** — case-insensitive match on `users.email`.
2. **Registration number** — exact match on `users.registration_number` or claim in `student_registrations`.
3. **Staff number** — normalize: strip spaces/upper; accept `KIU-0001`, `KIU0001`, `0001` → canonical `KIU-0001`; match `users.staff_number`.
4. **Synthetic staff email** — `<local>@staff.qaat.local` (QAAT rename of `staff.upanel.local`); constructed from staff number; not a real mailbox.
5. **Admin registration pattern** — `KIU\d+[A-Z]` style (current accepts for kiu_admin self-registration path).

Failure always: HTTP 401 `"Wrong email or password."` (no enumeration of which identifier was wrong / whether user exists).

---

## 3. Permission matrix (QAAT server-side enforcement)

The current system enforces roles **only in the mobile client and Django admin**. The document router accepts any authenticated user's read/write on any collection (`backend/documents/views.py` — `permission_classes=[IsAuthenticated]`, no collection policy). **QAAT must enforce the following server-side** (fix for gap [15](15-gaps-and-fixes.md) §1).

### 3.1 Document collections

| Collection | student | lecturer | qa_staff | administrator | kiu_admin |
|---|---|---|---|---|---|
| `attendance/lists` | R (lists they signed into); C (limited self-service) | CRUD (assigned/own) | CRUD all | CRUD all | CRUD all |
| `attendance/sessions` | R (linked) | CRUD (own lists) | CRUD all | CRUD all | CRUD all |
| `attendance/check-in-attempts` | C own; R own | R own lists | R/W all | R/W all | R/W all |
| `attendance/records` | R own | R/W own lists (mark absent) | R/W all | R/W all | R/W all |
| `attendance/students` | R/C own entries | R own lists | CRUD all | CRUD all | CRUD all |
| `attendance/sign-ins` | R/C own | R own lists | CRUD all | CRUD all | CRUD all |
| `attendance/health` | R (geofence, connectivity) | R | CRUD | CRUD | CRUD |
| `notices` | R (audience-filtered); no C | C (scoped audiences) / R | CRUD | CRUD | CRUD |
| `accounts/users` | R self | R (lecturers list minimal) | CRUD | CRUD | CRUD |
| `accounts/admins` | none | none | R | CRUD | CRUD |
| `accounts/lecturers` | R minimal | R | CRUD | CRUD | CRUD |
| `accounts/student-registrations` | R/C self claim | R | CRUD | CRUD | CRUD |
| `accounts/staff-numbers` | none | R | CRUD | CRUD | CRUD |
| `campus/presence` | none | none | CRUD | CRUD | CRUD |

R = read, C = create, W = update, D = delete. "Own"/"assigned" scoping must be verified by the Go router (e.g., student may only create attempts where `studentId == own uid`).

### 3.2 Auth endpoints

All authenticated users may call `/me`, change password, logout, register push device. `/request-verification` only if `email_verified=false`.

### 3.3 Filament (admin panel)

`is_staff=true` required for Filament login (parity with Django admin). Within Filament, KIU admin vs QA vs administrator distinctions are display/audit concerns; Filament users map 1:1 to `users` rows with `role` and `is_staff`.

---

## 4. Registration flows

### 4.1 Student self-registration

`POST /api/auth/register/` body: `{email, password, full_name, registration_number}`.

Rules (current `backend/accounts/views.py` + serializers):

- `password` ≥ 6 chars.
- Email unique; registration number unique across `users` **and** `student_registrations` (claim reserved even before verify).
- Username = email.
- Always `role=student`.
- Returns `{token, user}` immediately (account usable before email verified — current behavior; QAAT may optionally withhold token until verified, but that changes UX; keep parity unless product decides otherwise).
- Queues verification email (signup skips 60s cooldown).

### 4.2 Staff self-registration (client-driven)

`kiu_staff_register_screen.dart` flow:

1. Student/staff enters KIU email (`@kiu.ac.ug`) or staff number path.
2. Account created or matched; email verification required.
3. After verify: optional **KIU administrator onboarding** (`kiu_admin_onboarding_screen.dart`) asks "Are you a KIU administrator?" → sets `kiu_admin_job_title`, flips role if approved (current trusts client assertion; QAAT recommendation: require admin approval queue — see [15](15-gaps-and-fixes.md) §8).

### 4.3 QA-created staff

Staff hub screens (`register_staff_screen.dart`, `register_administrator_screen.dart`, `register_kiu_administrator_screen.dart`) — QA/admin creates account with generated staff number `KIU-####` and default password; shows credentials once (`staff_credentials_screen.dart`).

---

## 5. Email verification

Current: `backend/accounts/services/email_verification.py`.

| Aspect | Value |
|---|---|
| Token | 32-byte urlsafe, stored **sha256-hex** |
| TTL | **48 hours** |
| Single-use | `used_at` stamped |
| Link | `PUBLIC_API_URL/api/auth/verify-email/?token=…` |
| Resend cooldown | 60s + 5/hour (signup skips cooldown) |
| On success | `email_verified=true`; set `emailVerifiedAtLink` on all `accounts/student-registrations` docs for that uid; re-sync user projections |
| Delivery | Celery task `accounts.send_verification_email`, Mailjet with SMTP fallback, branded HTML template (`backend/accounts/services/email_templates.py`) |

GET verify endpoint returns **HTML** page (mobile deep-links via `APP_RETURN_URL`, default `qaat://open/email-verified` after rename) with Android package meta for App Links.

QAAT: port as Go handler + Python worker; keep HTML templates (rebrand U-Panel → QAAT, logo swap).

---

## 6. Password reset

Current: `backend/accounts/services/password_reset.py`.

| Aspect | Value |
|---|---|
| Token | 32-byte urlsafe, sha256-hex stored |
| TTL | **2 hours** |
| Single-use | consume token + **all other outstanding tokens** for user |
| Rate limit | 60s cooldown + 5/hour per user |
| Synthetic staff emails | `*@staff.qaat.local` **ignored** (no email sent) |
| On confirm success | set new password; **delete all auth tokens** (forces re-login everywhere) |
| Response | generic always (no "user not found" leak) |

Confirm endpoints render **HTML** (form GET + result POST).

---

## 7. Password change (authenticated)

`POST /api/auth/password-change/` `{current_password, new_password}`:

- Verify current; new ≥ 6 chars.
- Rotate: delete old token, issue new token (returned in `{token}`).
- Alias endpoint `/api/auth/change-password/` (current has both).

---

## 8. Tokens

| Aspect | Current | QAAT recommendation |
|---|---|---|
| Type | DRF `authtoken` — opaque random key | Keep opaque or switch to signed JWT (HS256) with short TTL + refresh |
| Count | **One active token per user** (`get_or_create`) | Allow multiple (multi-device) with `last_used_at`; logout revokes one |
| Expiry | None (until logout/password reset/delete) | Add 30-day sliding expiry + refresh token |
| Header | `Authorization: Token <key>` | `Authorization: Bearer <jwt>` if JWT chosen |
| Revocation | Logout, password reset, account delete | Same + refresh-token family revocation |

Mobile client stores token in secure storage (`lib/core/api/api_auth.dart`); web uses memory + refresh. QAAT Flutter port must keep restore-session on cold start (`AuthRepository.restoreSession`).

---

## 9. Account deletion

`DELETE /api/auth/me/` (current): deletes tokens + user row; cascades registrations/claims/devices + document projections (`accounts/users`, `admins`, `lecturers`, etc.).

Client shows explainer (`delete_account_screen.dart`). QAAT: soft-delete (`is_active=false` + anonymize PII) recommended over hard delete for audit; keep hard delete as admin action.

---

## 10. Push-device auth

`POST /api/push/register/` requires auth; user may only register devices for **their own** uid (implicit — device row keyed by `player_id` → `user_id = caller`). Tags must be consistent with role (e.g., a student cannot set `lec_<other>` tags — QAAT validation recommended).

---

## 11. Session / deep links

| Link | Purpose |
|---|---|
| `qaat://open/email-verified` | Custom scheme (replaces `upanel://`) |
| `https://<domain>/app` | Android App Links / iOS Universal Links (verified) |

Current Android package `com.u_panel` → QAAT package per [14 — Rename](14-rename-migration-playbook.md).

---

## 12. Auth test matrix (port from current)

Current tests: `backend/accounts/tests/test_login_identifier.py`, `test_email_verification_signup.py`, `test_password_reset.py`.

QAAT acceptance tests must cover:

1. Login via email / reg no / staff number / synthetic email / admin pattern.
2. Wrong password → 401 with fixed message.
3. Register duplicate email / duplicate reg no → 400.
4. Verification token valid/expired/reused.
5. Verification resend cooldown (429) and hourly cap (429).
6. Reset token valid/expired; multi-token invalidation on confirm.
7. Reset for synthetic staff email → no email sent, generic response.
8. Password change rotates token (old token 401 after).
9. Delete account cascades.
10. **QAAT new:** role-based collection access (student cannot write another's attempt; student cannot write `campus/presence`; etc.).
