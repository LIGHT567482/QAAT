# 14 — Rename & Migration Playbook

Ordered checklist to rename **django-U-Panel / U-Panel → QAAT** across the repository, mobile apps, backend, and online hosting. This is a **runbook** — execute top to bottom; check off each item.

Scope reminder from [01 — System Overview](01-system-overview.md) §5: two strategies exist. This playbook assumes **fresh QAAT build** (new repo) primarily, with an **in-place rename** appendix if you refactor the current monorepo first.

---

## Phase 0 — Decisions (before touching anything)

- [ ] **Product name:** QAAT (confirmed).
- [ ] **GitHub repo name:** e.g. `QAAT` or `qaat` (GitHub redirects old `django-U-Panel` URLs automatically after rename — verify once).
- [ ] **Dart package name:** `qaat` (must be valid Dart identifier: lowercase, underscores OK).
- [ ] **Android applicationId:** pick once and freeze — e.g. `com.qaat.campus` or `ug.kiu.qaat`. Changing later breaks updates.
- [ ] **iOS bundle id:** same string as applicationId.
- [ ] **Deep-link scheme:** `qaat://` (replace `upanel://`).
- [ ] **Public domains:** API + web (e.g. `api.qaat.kiu.ac.ug`, `qaat.kiu.ac.ug`) — or keep `kiu.orion13.us` during transition.
- [ ] **Synthetic staff email domain:** `@staff.qaat.local` (replace `@staff.upanel.local`).
- [ ] **OneSignal app:** new app or reuse (if reuse, tags unchanged; if new, update app id everywhere).
- [ ] **Sentry projects:** new projects `qaat-api`, `qaat-worker`, `qaat-flutter`, `qaat-admin`.
- [ ] **Hive box name:** `qaat_attendance_queues` (with migration fallback).
- [ ] **Celery/worker app name:** `qaat` (or per-service).

Record decisions in a `RENAME_DECISIONS.md` at repo root or in this spec.

---

## Phase 1 — Create QAAT repo (fresh-build strategy)

- [ ] Create new GitHub repo `QAAT` (private until launch).
- [ ] Initialize monorepo layout, e.g.:

```
QAAT/
├── api/          # Go
├── worker/       # Python
├── admin/        # Laravel + Filament
├── apps/
│   └── mobile/   # Flutter (port of lib/ + android/ + ios/)
├── docs/
│   └── qaat-spec/  # copy of this spec set
├── docker-compose.yml
└── README.md
```

- [ ] Copy `docs/qaat-spec/` into the new repo's `docs/`.
- [ ] Add this spec set as the build source of truth; link from README.

---

## Phase 2 — Backend identifier rename (if porting from current Django first)

If you temporarily keep Django during transition, rename in-place before extracting Go/Python:

- [ ] Django project package `upanel` → `qaat_api` (update `manage.py`, `settings.py` references, celery app, wsgi/asgi).
- [ ] `INSTALLED_APPS` labels; `AUTH_USER_MODEL` unchanged path (`accounts.User`) unless renaming app.
- [ ] Env prefix: `DJANGO_*` → keep or move to `QAAT_*` (coordinate with deploy scripts).
- [ ] Brand strings in `admin_setup.py`, templates, email templates: "U-Panel" → "QAAT".
- [ ] Synthetic domain `staff.upanel.local` → `staff.qaat.local` in `login_identifier.py`, `password_reset.py`, seed commands.
- [ ] `APP_ANDROID_PACKAGE` default `com.u_panel` → new package; `APP_RETURN_URL` `upanel://` → `qaat://`.
- [ ] CSRF hardcoded origin `https://kiu.orion13.us` → new domain (or remove hardcode — see [15 — Gaps](15-gaps-and-fixes.md)).
- [ ] Celery beat schedule task names (`documents.*`, `notices.*`) keep module paths or rename consistently with `CELERY_BEAT_SCHEDULE`.
- [ ] Docker image names / compose service names (`upanel-web` → `qaat-api` etc.).
- [ ] `config/deploy.yml` (Kamal) app name `ovirion/upanel` → `qaat`.
- [ ] Nginx upstream conf filenames `upanel.conf` → `qaat.conf`.

**Data compatibility (do NOT rename):**

- Document collection names (`attendance/lists`, …).
- Field names (`sessionCode`, `studentId`, …).
- OneSignal tag grammar (`stu_`, `lec_`, `list_`, `kiu_admins`, `all_notices`).
- Record id scheme `{sessionId}_{studentId}`; missed-notice id.
- Join-code format `A12B` + legacy acceptance.

---

## Phase 3 — Flutter app rename

- [ ] `pubspec.yaml`: `name: qaat` (update all `package:u_panel/` imports → `package:qaat/`); `description`; display name in ` MaterialApp`.
- [ ] Folder `lib/` stays; package rename is pubspec + imports (IDE rename / `dart fix`).
- [ ] Android `android/app/build.gradle`: `applicationId` → QAAT package; `namespace`; labels in `AndroidManifest.xml` (`android:label` "U-Panel" → "QAAT").
- [ ] Android deep links: `android:host` unchanged if domain same; scheme `upanel://` → `qaat://`; App Links `https://<domain>/app`.
- [ ] Android `google-services.json` if Firebase used for anything (currently OneSignal primary — verify).
- [ ] iOS `ios/Runner.xcodeproj`: `PRODUCT_BUNDLE_IDENTIFIER` → QAAT; `CFBundleDisplayName` "U-Panel" → "QAAT"; URL scheme `upanel` → `qaat`.
- [ ] iOS `Info.plist`: `NSLocationWhenInUseUsageDescription` text rebrand if desired; ATS entries for new API host.
- [ ] Deep link handling code: search for `upanel://`, `com.u_panel`, `u_panel`, "U-Panel" strings in `lib/` and platform folders; replace.
- [ ] Hive box name + migration: read old `u_panel_attendance_queues` if present, copy keys to `qaat_attendance_queues`, delete old (run once on boot).
- [ ] API base config (`lib/core/api/api_config.dart`): default URL → QAAT API; `--dart-define` names (`API_URL`, `UPANEL_API_BASE_URL` → `QAAT_API_BASE_URL` — keep old as fallback alias during transition).
- [ ] Sentry DSN / OneSignal app id in build scripts and CI.
- [ ] Web build output title/meta (index.html) rebrand.
- [ ] Update Flutter tests referencing old names.

---

## Phase 4 — Online repo & hosting rename

### 4.1 GitHub

- [ ] Rename repository: GitHub → Settings → Repository name → `QAAT`.
- [ ] GitHub auto-redirects old clone/fetch URLs; update local remote anyway:

```bash
git remote set-url origin git@github.com:<org>/QAAT.git
```

- [ ] Update any CI secrets / deploy keys referencing old name.
- [ ] Update README badges, release names.
- [ ] Transfer to final org/team if needed.

### 4.2 Local clone

- [ ] `mv django-U-Panel QAAT` (or re-clone); update IDE workspace.
- [ ] Search-repo for remaining `django-U-Panel`, `U-Panel`, `upanel`, `u_panel` strings; fix stragglers (case-insensitive).

### 4.3 Domains & DNS (Cloudflare)

- [ ] Add new DNS A/CNAME records for QAAT API + web (or repoint existing).
- [ ] SSL certificates (Cloudflare origin / Let's Encrypt).
- [ ] Update Nginx server_name; CORS allowed origins in backend env; CSRF trusted origins.
- [ ] Update `PUBLIC_API_URL` used in email links.
- [ ] Android App Links / iOS Universal Links: upload new assetlinks.json / apple-app-site-association for the new domain + package/bundle ids.
- [ ] Lower DNS TTL before cutover; raise after.

### 4.4 Third-party consoles

- [ ] **OneSignal:** create/rename app; update REST key + app id in env and mobile config; verify tags.
- [ ] **Mailjet:** update sender domain/name if brand requires; templates rebrand.
- [ ] **Sentry:** new projects + DSNs per service.
- [ ] **Cloudflare:** zone settings, cache rules, WAF for new hostname.
- [ ] **GitHub Pages / web host:** update workflow repo name, CNAME file (current `docs/CNAME`).
- [ ] **VPS scripts:** update Contabo scripts paths/repo clone URL.

---

## Phase 5 — Verification

- [ ] `grep -ri "u-panel\|upanel\|u_panel\|django-U-Panel" --exclude-dir=.git` → only intentional legacy references (e.g., this playbook, migration code) remain.
- [ ] Android build installs with new applicationId (uninstall old first if same device).
- [ ] iOS build runs; deep link `qaat://open/email-verified` opens app.
- [ ] Email verification + password-reset links hit QAAT API and deep-link correctly.
- [ ] Push notifications arrive on new OneSignal app with correct tags.
- [ ] Attendance end-to-end: create list → start session → student check-in → record → roll.
- [ ] Filament admin loads at `/admin/`; metrics populate.
- [ ] Health endpoint green; Sentry receives test events from each service.
- [ ] CI builds pass (Flutter analyze/test, Go test, Python test, Filament pint/dusk smoke).

---

## Appendix A — In-place rename strategy (current monorepo)

Use if you must rename **this** repo rather than start fresh:

1. Execute Phase 2 (backend) + Phase 3 (Flutter) in a branch; big-bang PR.
2. Phase 4.1 GitHub rename the same repo (`django-U-Panel` → `QAAT`).
3. Run Phase 5 verification on main.
4. Then incrementally extract Go/Python/Filament services per [02 — Architecture](02-architecture.md), keeping Django API as compatibility shim until parity.

Risk: long-lived branch conflicts; coordinate freezes.

---

## Appendix B — Strings inventory (search targets)

Run these searches before declaring rename done:

```
u_panel
U-Panel
U_PANEL
upanel
Upanel
django-U-Panel
staff.upanel.local
com.u_panel
upanel://
kiu.orion13.us          # if changing domain
ovirion/upanel          # Kamal
u_panel_attendance_queues
UPANEL_API_BASE_URL
```

Replace with QAAT equivalents; keep historical references in git history and this playbook.

---

## Appendix C — Post-rename data migration (optional)

If adopting existing production data:

1. Dump U-Panel Postgres.
2. Run ETL: `documents_apidocument` → typed QAAT tables by collection; leftover rows → QAAT `documents` table (preserve `doc_id` as PK; `data` JSON unchanged).
3. Copy `auth_user` (+ tokens, registrations, push devices) → QAAT `users` / related tables (hash passwords remain valid if using same algo — Django PBKDF2 may need rehash-on-login or bulk argon2 migration).
4. Row-count verification per collection; spot-check records for known sessions.
5. Re-index; run adjudication against a copy of production sessions for regression.

Skip if starting QAAT empty (recommended for v1).
