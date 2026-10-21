# 10 — Campus Presence

Staff and KIU administrators record **campus check-in / check-out** against a campus-wide geofence, with time-based policy classification (on-time, early departure, overwork). This powers the KIU-admin dashboard and the admin presence reports.

**Current sources:** `lib/features/campus_presence/` (full feature), `backend/campus/` (dormant ORM — live data via document store `campus/presence` + geofence doc `attendance/health` → `campus/geofence`), `campus_presence` queue in Hive.

**Note:** The Django `campus` app models (`CampusGeofence`, `AdminCampusPresence`) and `GeofenceView` are **unwired/dormant** in the current system — clients use the document router. QAAT implements campus presence as first-class typed tables (see [03 — Database](03-database.md) §5).

---

## 1. Roles & access

- **Who checks in/out:** KIU administrators (and administrators) physically on campus.
- **Who views:** same users + QA for oversight rolls; students/lecturers have no campus-presence powers.
- **Geofence admin:** update campus area (min radius **1.5 km** enforced for QA in `campus_geofence_validation.dart`).

---

## 2. Campus geofence

Stored as singleton (document `attendance/health` → `campus/geofence` or typed `campus_geofence` table):

| Field | Type | Notes |
|---|---|---|
| `latitude` / `longitude` | double | campus centre |
| `radius_meters` | int | default 200 ORM; client options 100/200/500/1500; **QA min 1500** |
| `label` | string | display name |
| `updated_at` | iso | |
| `updated_by_uid` / `updated_by_name` | string | audit |

Client caches in Hive (`cached_campus_geofence_v1`) until admin updates. Validation: `campus_geofence_validation.dart` (haversine + buffers similar to session geofence).

Update UI: `update_campus_location_screen.dart` ("Campus check-in area" in admin desktop sidebar).

---

## 3. Policy thresholds

`campus_presence_policy.dart`:

| Classification | Rule |
|---|---|
| **On-time** check-in | Arrival ≤ **08:30** (local) |
| **Early departure** | Check-out before **17:00** |
| **Overwork** | Check-out (or presence) after **17:30** |

Exact bucket logic (port client enums): events timestamped with device local time + UTC; `local_date_key` (`YYYY-MM-DD`) groups a person's day. QAAT server should recompute classifications from stored events (do not trust client labels alone) using campus timezone (Africa/Kampala, UTC+3) — current system uses device local date which can skew; see [15 — Gaps](15-gaps-and-fixes.md) §10.

---

## 4. Events

`campus_presence` collection/table:

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `admin_uid` | string | who |
| `event_type` | string | `check_in` / `check_out` / (optional `override`) |
| `latitude` / `longitude` | double | |
| `captured_at` | iso | |
| `local_date_key` | `YYYY-MM-DD` | grouping |
| `metadata` | json | accuracy, device, notes |
| `created_at` | iso | |

### 4.1 Check-in / check-out flow (client)

1. KIU-admin dashboard hero actions (`kiu_admin_dashboard_screen.dart`): big "Check in" / "Check out" buttons.
2. Policy hint displayed (8:30 / 5:00 / 5:30 rules).
3. GPS acquire (`campus_presence_check_progress.dart`); validate against campus geofence (`campus_geofence_validation.dart`).
4. Create event row; enqueue `pending_campus_presence_queue.dart` if offline.
5. Drain via `pending_campus_presence_sync` on reconnect (part of offline drain chain, [12](12-offline-and-sync.md)).

Repository: `campus_presence_repository.dart`. Actions helper: `campus_presence_check_actions.dart`.

---

## 5. Dashboards & views

- **KIU admin dashboard** (`kiu_admin_dashboard_screen.dart`): hero check-in/out, campus area card, records button, presence summary.
- **Presence card** (`admin_campus_presence_card.dart`): today's status snapshot.
- **Log** (`campus_presence_log_screen.dart`): chronological events.
- **Absent list** (`admin_campus_absent_list_screen.dart`): staff with no check-in for a date (within policy window).
- **Staff detail** (`campus_presence_staff_detail_screen.dart`): per-person history.
- **Check-in records** (`kiu_admin_check_in_records_screen.dart`): bulk records view.
- Status grouping widgets; `kiu_admin_ui.dart` design kit.

### 5.1 Day status model

`AdminCampusDayStatus` (client): per admin per `local_date_key` — first check-in, last check-out, classifications (on-time/late/early/overwork), event count. Computed client-side from events; QAAT server should expose the same aggregation endpoint for reports.

---

## 6. Reports

- **Admin presence roll** (`reports_admin_presence_roll_screen.dart`): admins × dates grid; export `admin_presence_roll_export.dart`.
- Weekly check-in counts card (KIU administrator card on reports hub).

See [11 — Reports & Roll](11-reports-and-roll.md) for export formats.

---

## 7. Offline behavior

- Events queue in Hive (`pending_campus_presence`, part of `AttendanceLocalQueues`).
- Drain order includes campus presence after check-ins in the full drain chain (`attendance_offline_sync.dart`).
- `purgeExpiredPendingOnly` applies same 7-day retention concept; campus events are not converted to "absent" automatically — absence is computed at report time from missing events.

---

## 8. QAAT implementation checklist (campus presence)

- [ ] `campus_geofence` singleton table + admin update endpoint + Filament settings page.
- [ ] `campus_presence` table + CRUD API (role-gated: admin/kiu_admin create; QA/admin read).
- [ ] Server-side classification recompute (on-time/early/overwork) in campus timezone; expose per-day status endpoint.
- [ ] Absent-list query endpoint (staff with no check-in for date).
- [ ] Flutter: KIU-admin dashboard hero actions, geofence validation, queue + sync, all screens (log, absent, detail, records).
- [ ] Reports: admin presence roll + CSV export.
- [ ] Tests: geofence validation, policy buckets, offline queue drain, timezone handling.
