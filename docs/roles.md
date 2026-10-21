# QAAT — Roles, Permissions & Access

The five roles, what each can do, and how sign-in works. This condenses the
spec's [05 — Auth & Roles](qaat-spec/05-auth-and-roles.md) for this stack.
Behavior details live in the spec; this is the at-a-glance reference.

- Stack & deviations → [architecture.md](architecture.md)
- Rename & open decisions → [decisions.md](decisions.md)

> **On credentials.** This file documents **default / seeded** credentials and the
> *mechanism* each group authenticates with. It contains no real user passwords.
> Every default is a **first-login credential that must be changed**.

---

## 1. The five roles

Five roles exist (`users.role` CHECK — spec doc 03). A user's role is resolved
at login and carried in the token; **the server enforces it on every operation**
(permission matrix — spec doc 05 §3; **403** on violation). This is spec gap
**#1 (S1)**: the legacy system had *no* server-side authorization, and QAAT must
not ship that bug.

| Role key | Who | Surface | Primary powers |
|---|---|---|---|
| `student` | Enrolled students (default role at registration) | **Flutter** — **no dashboard**; nav = Attendance, Notices, Profile | Sign into class lists, check in to sessions, view own attendance, receive notices |
| `lecturer` | Teaching staff | **Flutter** | Create/edit class lists, start/end sessions, view rolls for own lists, create targeted notices |
| `qa_staff` | Quality-assurance staff | **Next.js** (shared dashboard with administrator) | All lecturer powers + oversight of every list/session, start overdue sessions, staff management, reports |
| `administrator` | System administrators | **Next.js** | Full operations: users, notices, reports, dashboards, staff administration |
| `kiu_admin` | Senior KIU administrators | **Next.js** (own dashboard, campus hero actions) | Everything administrator can do + campus presence check-in/out + KIU-admin-only notices |

**Derived flags** (computed, never stored — spec doc 05 §1):

- `is_administrator` = `qa_staff | administrator | kiu_admin`
- `hasLecturerAttendanceAccess` = `lecturer | kiu_admin`
- `hasStaffOperationalAccess` = `qa_staff | administrator`

**Roles are server-derived, never user-picked at runtime.** Clients resolve
flags from `GET /api/auth/me/`.

---

## 2. What each role does

### Student — `student`
Created by self-registration (always `role=student`). Signs into class lists,
checks in to sessions (join code `A12B` + geofence, with 7-day offline queueing —
doc 12), views own attendance, receives notices. Nav is exactly
**Attendance · Notices · Profile** (no dashboard — doc 07).

### Lecturer — `lecturer`
Creates/edits class lists, starts/ends sessions (duration + GPS geofence +
client-generated join code, four double-start guards — doc 06 §3), views rolls
for own lists, creates notices scoped to own lists. Rolls close on **End**;
unchecked roster students show **Pending** for up to 7 days, then Absent.

### QA staff — `qa_staff`
All lecturer powers **plus** oversight of every list/session: start sessions for
overdue classes (+1h30 overdue screen), review rolls, reprocess check-ins, staff
management, reports. Reads campus presence (cannot check in/out themselves).

### Administrator — `administrator`
Full operations: users, notices, reports, dashboards, staff administration.
Typically creates staff accounts (staff self-registration or QA-created with
generated `KIU-####` numbers).

### KIU admin — `kiu_admin`
Everything `administrator` can do, **plus** campus presence check-in/out against
the campus geofence (on-time ≤ 08:30, early departure < 17:00, overwork > 17:30
— doc 10, recomputed server-side in Africa/Kampala), KIU-admin-only notices
(audience `kiuAdmins`), and onboarding (spec gap #8: must become an approval
queue — never trust a client self-assertion).

---

## 3. Permission matrix (summary)

Full matrix: [spec doc 05 §3](qaat-spec/05-auth-and-roles.md). R = read,
C = create, W = update, D = delete. "Own/assigned" scoping is verified by the
Go API (e.g. a student may only create attempts where `studentId` = own uid).

| Collection | student | lecturer | qa_staff | administrator | kiu_admin |
|---|---|---|---|---|---|
| `attendance/lists` | R (signed-in) / C self-service | CRUD own | CRUD all | CRUD all | CRUD all |
| `attendance/sessions` | R linked, **no C** | CRUD own | CRUD all | CRUD all | CRUD all |
| `attendance/check-in-attempts` | C own, R own | R own lists | R/W all | R/W all | R/W all |
| `attendance/records` | R own | R/W own | R/W all | R/W all | R/W all |
| `attendance/students`, `attendance/sign-ins` | R/C own | R own lists | CRUD all | CRUD all | CRUD all |
| `attendance/health` | R (geofence) | R | CRUD | CRUD | CRUD |
| `notices` | R audience-filtered, **no C** | C (scoped) / R | CRUD | CRUD | CRUD |
| `accounts/users` | R self | R (minimal) | CRUD | CRUD | CRUD |
| `accounts/admins` | none | none | R | CRUD | CRUD |
| `accounts/lecturers` | R minimal | R | CRUD | CRUD | CRUD |
| `accounts/student-registrations` | R/C self claim | R | CRUD | CRUD | CRUD |
| `accounts/staff-numbers` | none | R | CRUD | CRUD | CRUD |
| `campus/presence` | none | none | CRUD | CRUD | CRUD |

In this build the document-router collections map onto the per-role API groups
(`/api/student`, `/api/lecturer`, `/api/admin`); the matrix above is the
authorization rule each group enforces (deviation #4 — [architecture.md](architecture.md)).

---

## 4. Authentication

- **Identifier resolution order** (login): email (case-insensitive) → registration
  number → staff number (`KIU-0001` / `KIU0001` / `0001` → `KIU-0001`) → synthetic
  `<local>@staff.qaat.local` → admin pattern `KIU\d+[A-Z]`.
  Failure is always **401 `"Wrong email or password."`** (no user enumeration).
- **Token**: HS256 JWT, 2 h TTL (spec doc 05 §8), sent as `Authorization: Bearer <jwt>`
  (the legacy `Authorization: Token <key>` form is also accepted).
  Logout / password reset / account delete revoke it. Mobile restores the session
  on cold start.
- **Registration**: email unique, reg-no unique across `users` **and**
  `student_registrations`, password ≥ 6 chars, always `role=student`. Token is
  returned before email verification (parity).
- **Email verification**: 32-byte urlsafe token, sha256-hex stored, **48 h** TTL,
  single-use; resend rate-limited (60 s cooldown, 5/hour). HTML result page +
  `qaat://open/email-verified` deep link.
- **Password reset**: **2 h** TTL, single-use, consumes all outstanding tokens;
  generic response always; synthetic staff emails (`*@staff.qaat.local`) ignored;
  success deletes all auth tokens (forces re-login everywhere).
- **Password change**: verify current, new ≥ 6 chars, rotate token.
- **Push registration** (`POST /api/push/register/`): server derives authoritative
  OneSignal tags from role + list memberships; a client cannot set privileged tags
  (spec gap #21). Grammar: `stu_<uid>`, `lec_<uid>`, `list_<listId>`, `kiu_admins`, `all_notices`.

---

## 5. Access surfaces

| Surface | Who | Where |
|---|---|---|
| **Flutter app** (Android/iOS/web) | `student`, `lecturer` | `frontend/mobile/` |
| **Next.js dashboards** (responsive web) | `qa_staff`, `administrator`, `kiu_admin` | `frontend/web/` |
| **Go API** (`/api/*`) | all roles | `backend/` |

No separate staff mobile app: staff surfaces are the responsive Next.js dashboards
(deviation #2 — [architecture.md](architecture.md)).

### Demo credentials

After `make seed` (password `qaat-demo-1` for all):
`student@kiu.ac.ug` · `lecturer@kiu.ac.ug` · `qa@kiu.ac.ug` ·
`admin@kiu.ac.ug` · `kiuadmin@kiu.ac.ug`.
