# 11 — Reports & Roll

QAAT's reporting centers on the **three-state roll** (Present / Absent / Pending) and derived attendance percentages, plus lecturer-teaching and campus-presence rolls. All roll computation is **client-side** in the current Flutter app; QAAT may add server-side aggregation endpoints but must preserve the exact cell/percentage semantics below.

**Current sources:** `lib/features/attendance/roll_cell_status.dart` (cell resolution), `lib/features/reports/attendance_list_roll.dart` (grid build), `lib/features/reports/reports_csv_data.dart` (export), `lib/features/attendance/student_session_grace.dart` (grace), `docs/U_PANEL_ALGORITHMS.md` §1 (algorithm catalog).

---

## 1. Three-state roll

Labels (`roll_cell_status.dart` L11–13):

- `kRollLabelPresent` = **Present**
- `kRollLabelAbsent` = **Absent**
- `kRollLabelPending` = **Pending**
- `null` = no cell (session doesn't count / discarded / grace not expired without record)

**There is no "Late" or "Excused" state** — strictly three states + null. Late arrivals (after `endTime` while session still active) still record as **Present** ([06](06-attendance-module.md) §9.4).

Grid (`attendance_list_roll.dart` `buildAttendanceListRoll` L73–170):

- Roster = `AttendanceStore.rollStudentIdsForList`; students merged by **registration-number key** (dedupe multiple ids per reg, L87–106).
- Per student per session: cell = `rollCellLabelForStudentSession(...)`.
- Percentage per student = `rollRateCountsForStudentOnList(...).percentRounded` over sessions where `countsTowardRollStats`.
- Roll totals: `presentRollRows` / `pendingRollRows` / `absentRollRows` (L39–66).
- Plain-text export (L175–198): `%`, name, reg, one column per session (`—` for null).

---

## 2. Cell resolution priority

`rollCellLabelForStudentSession` (`roll_cell_status.dart` L227–288), evaluated in order:

1. Any local record for the session with `present == true` → **Present** (even unverified — comment L248–250).
2. `pending.studentHasOfflineTrustedPresent` → **Present** (approved/trusted queue rows; context from `RollPendingContext.load()` L83–204).
3. Session awaiting upload **or** metadata incomplete (`locationMetadataPending`) → **Pending** (L261–264).
4. `studentHasPendingPresent` → **Pending** (L266–268).
5. Any record with `present == false` → **Absent** (unless session doesn't count → null) (L270–273).
6. Session not counting (`countsTowardRollStats` false) → null (L275).
7. `missedBeforeJoin` (session ended before student's earliest list sign-in) → **Absent** (L277).
8. Grace not expired → **null** ("session still open / grace running", L278–286); grace expired → **Absent**.

### 2.1 Record merge

`_mergeRollRecord` (L328–338): **verified present > unverified present > absent**; newest timestamp wins between two absents.

### 2.2 Offline trust

`offline_capture_trust.dart`: offline-queued check-in "trusts present" only if `entry.listId == session.listId` when set (L8–17); blocking rules for finalize (L50–62). Offline-trusted present with conflicting absent record counts as present for percentage (roll L393–405).

---

## 3. Grace period

`student_session_grace.dart` L10–27; retention `pending_retention.dart` L6–18:

- After a session ends, a student with **no resolved record** is neither counted present nor absent for **7 days** (cell null; excluded from percentage denominator).
- After 7 days (or when a later present on the same list resolves the evidence), the student is marked **Absent** (implicit absent added at percentage time if `graceExpired` or `missedBeforeJoin`).
- Server/client purge (`purgeExpiredPendingOnly`, `_markUnverifiedCheckInAbsent`) converts expired **unverified check-ins** to explicit `present:false` records.
- Reaping job/client: `finalizeGraceExpiredSessions()` (L2746–2751), called from offline drain.

---

## 4. Percentage formula

`rollRateCountsForStudentOnList` (`roll_cell_status.dart` L363–452) + `RollRateCounts.percentRounded` (L454–462):

```
For each session where countsTowardRollStats(session) is true:
  if present evidence (record or trusted pending)     → present++ , total++
  else if resolved absent (record false, missedBeforeJoin, or grace expired)
                                                      → total++
  else (pending evidence, awaiting upload, metadata-incomplete,
        or inside grace without record)               → skip (neither present nor total)

percentRounded = total <= 0 ? 0 : round(100 * present / total).clamp(0, 100)
```

`countsTowardRollStats` (models L261–263) = not `rollDiscarded` AND (past `endTime` OR `closed`).

**Pending never depresses the percentage** — excluded from both numerator and denominator (`rollCellCountsTowardRate` L357–358). Extra loop adds orphan records on the same list not seen via `completedSessions` (L440–449).

---

## 5. Session inclusion

A session is **included** in rolls when:

- `status` is closed or `endTime` has passed (client treats open sessions as Pending/incomplete).
- `rollDiscarded` is false (discard path sets this / deletes the session).

Open/incomplete sessions → cells Pending, excluded from rate (L420–423, 261–264).

---

## 6. Report types

### 6.1 Attendance list roll (primary)

- Screen: `attendance_list_roll_screen.dart`.
- Grid: students (rows) × sessions (columns), colored Present/Pending/Absent; per-student % column.
- Export: **CSV** (UTF-8 **BOM** + clipboard copy + web download) via `reports_csv_data.dart`; **print** as plain text (mobile copies to clipboard, web opens dialog).
- Hierarchy navigation: day → program → year → semester → class list (`reports_attendance_hierarchy.dart`).

### 6.2 Lecturer teaching roll

- `reports_lecturer_teaching_screen.dart`: lecturers × dates; which dates taught, classes, rooms, durations.
- Export: `lecturer_teaching_roll_export.dart`.
- Data from lists' `lecturerUid` + `date` + sessions' start/end.

### 6.3 Admin (campus presence) roll

- `reports_admin_presence_roll_screen.dart`: admins × dates (campus check-in/out status).
- Export: `admin_presence_roll_export.dart`.
- See [10 — Campus Presence](10-campus-presence.md).

### 6.4 Reports hub

`reports_screen.dart`: KIU administrators card (arrivals/departures/late/overwork by date, weekly check-in counts), Lecturers card, Attendance rolls hierarchy, QA stats, refresh timestamp, print-all actions. Lecturer variant = "My class lists" (assigned only).

### 6.5 QA / lesson stats

QA stats card on hub; lesson insights (`lib/features/lesson_insights/`) computed from `AttendanceStore` — teaching load, session durations, period filters.

---

## 7. Export formats

| Format | Where | Notes |
|---|---|---|
| CSV | `reports_csv_data.dart`, `admin_presence_roll_export.dart`, `lecturer_teaching_roll_export.dart` | UTF-8 BOM for Excel; clipboard + file download (web) / share (mobile) |
| PDF / print | `reports_roll_pdf.dart`, `reports_pdf_text.dart`, `report_print.dart` | Plain-text layout on mobile (clipboard); web print dialog; PDF generation optional via `pdf`/`printing` packages |
| File save | `report_file_save.dart` (+`_io`/`_web`/`_stub`) | Platform-appropriate paths |

Period selection: `reports_export_period_dialog.dart`.

---

## 8. Live session snapshot

`liveSessionCheckInSnapshot` (`roll_cell_status.dart` L509–569) + `mergeWithRtd` (L497–505): merges RTD live stats by taking **maxima** (highest present counts win) for the lecturer's live view during an active session.

---

## 9. QAAT implementation checklist (reports & roll)

- [ ] Port `roll_cell_status.dart` logic **exactly** (priority order, merge, grace) — treat as golden reference; add unit tests for every branch.
- [ ] `attendance_list_roll` grid + CSV (BOM) + print/export parity.
- [ ] Lecturer teaching roll + export.
- [ ] Admin presence roll + export (data from campus presence).
- [ ] Hierarchy navigation (day/program/year/sem/list).
- [ ] Lesson insights service (optional server-side cache for large rosters).
- [ ] Grace reaping job parity (7-day → absent).
- [ ] `countsTowardRollStats` / discard / `locationMetadataPending` Pending behavior preserved.
- [ ] Optional QAAT enhancement: server-side roll aggregation endpoint for web dashboards (must match client math).
- [ ] Golden tests: every scenario in [06](06-attendance-module.md) §9 that affects roll output.
