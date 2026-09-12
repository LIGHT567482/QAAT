import 'package:sqflite/sqflite.dart';

import '../patrol/patrol_models.dart';

/// The QA monitor's offline store — the Room database of the native app, mirrored
/// table for table.
///
///   • `patrol_slots`   — the cached WEEK of timetabled lectures (offline search)
///   • `patrol_logs`    — lecture observations queued for `/patrol/sync`
///   • `office_people`  — the cached employee registry (offline office search)
///   • `office_visits`  — office observations queued for `/patrol/office/sync`
///
/// A monitor walks corridors with no signal, and the ticks they file there are the
/// whole point — so nothing about this store requires the network. Sync is a
/// "mark the row synced" after the batch is durably stored on the server.
abstract class PatrolStore {
  Future<void> replacePatrolSlots(List<PatrolSlot> slots);

  Future<List<PatrolSlot>> patrolSlotsForDay(int dayOfWeek);

  Future<void> putPatrolLog(PatrolLog log);

  Future<List<PatrolLog>> patrolLogsForDay(String date);

  Future<List<PatrolLog>> unsyncedPatrolLogs();

  Future<void> markPatrolLogSynced(String id);

  Future<int> pendingPatrolCount();

  Future<void> replaceOfficePeople(List<OfficePerson> people);

  Future<List<OfficePerson>> officePeople();

  Future<void> putOfficeVisit(OfficeVisit visit);

  Future<List<OfficeVisit>> officeVisitsForDay(String date);

  Future<List<OfficeVisit>> unsyncedOfficeVisits();

  Future<void> markOfficeVisitSynced(String id);

  Future<int> pendingOfficeCount();

  /// Both queues — the sign-out warning and the profile line count what cannot be
  /// re-sent after the handset's account is gone.
  Future<int> pendingSyncCount();

  /// Sign-out teardown. A monitor log names lecturers and must not outlive the
  /// session that produced it on a shared or surrendered handset, so every cached
  /// row — slots, logs, people and visits — is dropped.
  Future<void> clearAllForSignOut();
}

/// SQLite-backed store via `sqflite`. One database, opened lazily on first use.
class SqflitePatrolStore implements PatrolStore {
  SqflitePatrolStore._();

  static final SqflitePatrolStore instance = SqflitePatrolStore._();

  static const _dbName = 'qaat_patrol.db';
  Database? _db;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    final path = '${await getDatabasesPath()}/$_dbName';
    final db = await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE patrol_slots (
          unit_id TEXT NOT NULL,
          unit_name TEXT NOT NULL DEFAULT '',
          course_code TEXT NOT NULL DEFAULT '',
          lecturer_staff_id TEXT NOT NULL DEFAULT '',
          lecturer_name TEXT NOT NULL DEFAULT '',
          room TEXT NOT NULL DEFAULT '',
          day_of_week INTEGER NOT NULL,
          start_time TEXT NOT NULL,
          duration_minutes INTEGER NOT NULL DEFAULT 60,
          offering_id TEXT NOT NULL DEFAULT '',
          cohort TEXT NOT NULL DEFAULT '',
          also_here TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (unit_id, offering_id, day_of_week, start_time)
        )
      ''');
      await db.execute('''
        CREATE TABLE patrol_logs (
          id TEXT PRIMARY KEY,
          unit_id TEXT NOT NULL,
          unit_name TEXT NOT NULL DEFAULT '',
          course_code TEXT NOT NULL DEFAULT '',
          lecturer_id TEXT NOT NULL DEFAULT '',
          lecturer_name TEXT NOT NULL DEFAULT '',
          room TEXT NOT NULL DEFAULT '',
          session_date TEXT NOT NULL DEFAULT '',
          scheduled_time TEXT NOT NULL DEFAULT '',
          taught INTEGER NOT NULL DEFAULT 0,
          taken_at TEXT NOT NULL DEFAULT '',
          synced INTEGER NOT NULL DEFAULT 0,
          offering_id TEXT NOT NULL DEFAULT '',
          found_venue TEXT NOT NULL DEFAULT '',
          found_start_time TEXT NOT NULL DEFAULT '',
          found_date TEXT NOT NULL DEFAULT '',
          venue_changed INTEGER NOT NULL DEFAULT 0,
          remarks TEXT NOT NULL DEFAULT '',
          is_compensation INTEGER NOT NULL DEFAULT 0,
          compensation_for TEXT NOT NULL DEFAULT '',
          UNIQUE (offering_id, session_date, scheduled_time, unit_id)
        )
      ''');
      await db.execute('''
        CREATE TABLE office_people (
          staff_id TEXT PRIMARY KEY,
          full_name TEXT NOT NULL DEFAULT '',
          department TEXT NOT NULL DEFAULT '',
          job_title TEXT NOT NULL DEFAULT '',
          office TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute('''
        CREATE TABLE office_visits (
          id TEXT PRIMARY KEY,
          staff_id TEXT NOT NULL,
          employee_name TEXT NOT NULL DEFAULT '',
          department TEXT NOT NULL DEFAULT '',
          job_title TEXT NOT NULL DEFAULT '',
          office TEXT NOT NULL DEFAULT '',
          office_source TEXT NOT NULL DEFAULT 'TYPED',
          status TEXT NOT NULL,
          found_at TEXT NOT NULL DEFAULT '',
          remarks TEXT NOT NULL DEFAULT '',
          visit_date TEXT NOT NULL DEFAULT '',
          visit_time TEXT NOT NULL DEFAULT '',
          captured_at TEXT NOT NULL DEFAULT '',
          synced INTEGER NOT NULL DEFAULT 0,
          UNIQUE (staff_id, visit_date, id)
        )
      ''');
    });
    _db = db;
    return db;
  }

  @override
  Future<void> replacePatrolSlots(List<PatrolSlot> slots) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('patrol_slots');
      for (final s in slots) {
        await txn.insert('patrol_slots', s.toRow(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<List<PatrolSlot>> patrolSlotsForDay(int dayOfWeek) async {
    final db = await _database;
    final rows = await db.query('patrol_slots',
        where: 'day_of_week = ?', whereArgs: [dayOfWeek]);
    return rows.map(_slotFromRow).toList();
  }

  @override
  Future<void> putPatrolLog(PatrolLog log) async {
    final db = await _database;
    await db.insert('patrol_logs', _logToRow(log),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<PatrolLog>> patrolLogsForDay(String date) async {
    final db = await _database;
    final rows = await db.query('patrol_logs',
        where: 'session_date = ?', whereArgs: [date]);
    return rows.map(_logFromRow).toList();
  }

  @override
  Future<List<PatrolLog>> unsyncedPatrolLogs() async {
    final db = await _database;
    final rows = await db.query('patrol_logs',
        where: 'synced = 0', orderBy: 'taken_at ASC');
    return rows.map(_logFromRow).toList();
  }

  @override
  Future<void> markPatrolLogSynced(String id) async {
    final db = await _database;
    await db.update('patrol_logs', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<int> pendingPatrolCount() async {
    final db = await _database;
    final r = await db
        .rawQuery('SELECT COUNT(*) AS c FROM patrol_logs WHERE synced = 0');
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> replaceOfficePeople(List<OfficePerson> people) async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('office_people');
      for (final p in people) {
        await txn.insert('office_people', {
          'staff_id': p.staffId,
          'full_name': p.fullName,
          'department': p.department,
          'job_title': p.jobTitle,
          'office': p.office,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  @override
  Future<List<OfficePerson>> officePeople() async {
    final db = await _database;
    final rows = await db.query('office_people');
    return rows
        .map((r) => OfficePerson(
              staffId: r['staff_id'] as String,
              fullName: r['full_name'] as String? ?? '',
              department: r['department'] as String? ?? '',
              jobTitle: r['job_title'] as String? ?? '',
              office: r['office'] as String? ?? '',
            ))
        .toList();
  }

  @override
  Future<void> putOfficeVisit(OfficeVisit visit) async {
    final db = await _database;
    await db.insert('office_visits', _visitToRow(visit),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<OfficeVisit>> officeVisitsForDay(String date) async {
    final db = await _database;
    final rows = await db.query('office_visits',
        where: 'visit_date = ?', whereArgs: [date]);
    return rows.map(_visitFromRow).toList();
  }

  @override
  Future<List<OfficeVisit>> unsyncedOfficeVisits() async {
    final db = await _database;
    final rows = await db.query('office_visits',
        where: 'synced = 0', orderBy: 'captured_at ASC');
    return rows.map(_visitFromRow).toList();
  }

  @override
  Future<void> markOfficeVisitSynced(String id) async {
    final db = await _database;
    await db.update('office_visits', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<int> pendingOfficeCount() async {
    final db = await _database;
    final r = await db
        .rawQuery('SELECT COUNT(*) AS c FROM office_visits WHERE synced = 0');
    return (r.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<int> pendingSyncCount() async =>
      await pendingPatrolCount() + await pendingOfficeCount();

  @override
  Future<void> clearAllForSignOut() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('patrol_slots');
      await txn.delete('patrol_logs');
      await txn.delete('office_people');
      await txn.delete('office_visits');
    });
  }

  PatrolSlot _slotFromRow(Map<String, Object?> r) => PatrolSlot(
        unitId: r['unit_id'] as String,
        unitName: r['unit_name'] as String? ?? '',
        courseCode: r['course_code'] as String? ?? '',
        lecturerStaffId: r['lecturer_staff_id'] as String? ?? '',
        lecturerName: r['lecturer_name'] as String? ?? '',
        room: r['room'] as String? ?? '',
        dayOfWeek: (r['day_of_week'] as num).toInt(),
        startTime: r['start_time'] as String,
        durationMinutes: (r['duration_minutes'] as num?)?.toInt() ?? 60,
        offeringId: r['offering_id'] as String? ?? '',
        cohort: r['cohort'] as String? ?? '',
        alsoHere: r['also_here'] as String? ?? '',
      );

  Map<String, Object?> _logToRow(PatrolLog l) => {
        'id': l.id,
        'unit_id': l.unitId,
        'unit_name': l.unitName,
        'course_code': l.courseCode,
        'lecturer_id': l.lecturerId,
        'lecturer_name': l.lecturerName,
        'room': l.room,
        'session_date': l.sessionDate,
        'scheduled_time': l.scheduledTime,
        'taught': l.taught ? 1 : 0,
        'taken_at': l.takenAt,
        'synced': l.synced ? 1 : 0,
        'offering_id': l.offeringId,
        'found_venue': l.foundVenue,
        'found_start_time': l.foundStartTime,
        'found_date': l.foundDate,
        'venue_changed': l.venueChanged ? 1 : 0,
        'remarks': l.remarks,
        'is_compensation': l.isCompensation ? 1 : 0,
        'compensation_for': l.compensationFor,
      };

  PatrolLog _logFromRow(Map<String, Object?> r) => PatrolLog(
        id: r['id'] as String,
        unitId: r['unit_id'] as String,
        unitName: r['unit_name'] as String? ?? '',
        courseCode: r['course_code'] as String? ?? '',
        lecturerId: r['lecturer_id'] as String? ?? '',
        lecturerName: r['lecturer_name'] as String? ?? '',
        room: r['room'] as String? ?? '',
        sessionDate: r['session_date'] as String? ?? '',
        scheduledTime: r['scheduled_time'] as String? ?? '',
        taught: (r['taught'] as num? ?? 0) != 0,
        takenAt: r['taken_at'] as String? ?? '',
        synced: (r['synced'] as num? ?? 0) != 0,
        offeringId: r['offering_id'] as String? ?? '',
        foundVenue: r['found_venue'] as String? ?? '',
        foundStartTime: r['found_start_time'] as String? ?? '',
        foundDate: r['found_date'] as String? ?? '',
        venueChanged: (r['venue_changed'] as num? ?? 0) != 0,
        remarks: r['remarks'] as String? ?? '',
        isCompensation: (r['is_compensation'] as num? ?? 0) != 0,
        compensationFor: r['compensation_for'] as String? ?? '',
      );

  Map<String, Object?> _visitToRow(OfficeVisit v) => {
        'id': v.id,
        'staff_id': v.staffId,
        'employee_name': v.employeeName,
        'department': v.department,
        'job_title': v.jobTitle,
        'office': v.office,
        'office_source': v.officeSource,
        'status': v.status,
        'found_at': v.foundAt,
        'remarks': v.remarks,
        'visit_date': v.visitDate,
        'visit_time': v.visitTime,
        'captured_at': v.capturedAt,
        'synced': v.synced ? 1 : 0,
      };

  OfficeVisit _visitFromRow(Map<String, Object?> r) => OfficeVisit(
        id: r['id'] as String,
        staffId: r['staff_id'] as String,
        employeeName: r['employee_name'] as String? ?? '',
        department: r['department'] as String? ?? '',
        jobTitle: r['job_title'] as String? ?? '',
        office: r['office'] as String? ?? '',
        officeSource: r['office_source'] as String? ?? 'TYPED',
        status: r['status'] as String? ?? '',
        foundAt: r['found_at'] as String? ?? '',
        remarks: r['remarks'] as String? ?? '',
        visitDate: r['visit_date'] as String? ?? '',
        visitTime: r['visit_time'] as String? ?? '',
        capturedAt: r['captured_at'] as String? ?? '',
        synced: (r['synced'] as num? ?? 0) != 0,
      );
}

/// In-memory store for widget tests / host runs — same behaviour, no platform.
class InMemoryPatrolStore implements PatrolStore {
  final List<PatrolSlot> _slots = [];
  final List<PatrolLog> _logs = [];
  final List<OfficePerson> _people = [];
  final List<OfficeVisit> _visits = [];

  @override
  Future<void> replacePatrolSlots(List<PatrolSlot> slots) async {
    _slots
      ..clear()
      ..addAll(slots);
  }

  @override
  Future<List<PatrolSlot>> patrolSlotsForDay(int dayOfWeek) async =>
      _slots.where((s) => s.dayOfWeek == dayOfWeek).toList();

  @override
  Future<void> putPatrolLog(PatrolLog log) async {
    _logs
      ..removeWhere((l) => l.id == log.id)
      ..add(log);
  }

  @override
  Future<List<PatrolLog>> patrolLogsForDay(String date) async =>
      _logs.where((l) => l.sessionDate == date).toList();

  @override
  Future<List<PatrolLog>> unsyncedPatrolLogs() async =>
      _logs.where((l) => !l.synced).toList();

  @override
  Future<void> markPatrolLogSynced(String id) async {
    final i = _logs.indexWhere((l) => l.id == id);
    if (i >= 0) _logs[i] = _copyLog(_logs[i], synced: true);
  }

  @override
  Future<int> pendingPatrolCount() async =>
      _logs.where((l) => !l.synced).length;

  @override
  Future<void> replaceOfficePeople(List<OfficePerson> people) async {
    _people
      ..clear()
      ..addAll(people);
  }

  @override
  Future<List<OfficePerson>> officePeople() async => List.of(_people);

  @override
  Future<void> putOfficeVisit(OfficeVisit visit) async {
    _visits
      ..removeWhere((v) => v.id == visit.id)
      ..add(visit);
  }

  @override
  Future<List<OfficeVisit>> officeVisitsForDay(String date) async =>
      _visits.where((v) => v.visitDate == date).toList();

  @override
  Future<List<OfficeVisit>> unsyncedOfficeVisits() async =>
      _visits.where((v) => !v.synced).toList();

  @override
  Future<void> markOfficeVisitSynced(String id) async {
    final i = _visits.indexWhere((v) => v.id == id);
    if (i >= 0) {
      final v = _visits[i];
      _visits[i] = OfficeVisit(
        id: v.id,
        staffId: v.staffId,
        employeeName: v.employeeName,
        department: v.department,
        jobTitle: v.jobTitle,
        office: v.office,
        officeSource: v.officeSource,
        status: v.status,
        foundAt: v.foundAt,
        remarks: v.remarks,
        visitDate: v.visitDate,
        visitTime: v.visitTime,
        capturedAt: v.capturedAt,
        synced: true,
      );
    }
  }

  @override
  Future<int> pendingOfficeCount() async =>
      _visits.where((v) => !v.synced).length;

  @override
  Future<int> pendingSyncCount() async =>
      await pendingPatrolCount() + await pendingOfficeCount();

  @override
  Future<void> clearAllForSignOut() async {
    _slots.clear();
    _logs.clear();
    _people.clear();
    _visits.clear();
  }

  PatrolLog _copyLog(PatrolLog l, {required bool synced}) => PatrolLog(
        id: l.id,
        unitId: l.unitId,
        unitName: l.unitName,
        courseCode: l.courseCode,
        lecturerId: l.lecturerId,
        lecturerName: l.lecturerName,
        room: l.room,
        sessionDate: l.sessionDate,
        scheduledTime: l.scheduledTime,
        taught: l.taught,
        takenAt: l.takenAt,
        synced: synced,
        offeringId: l.offeringId,
        foundVenue: l.foundVenue,
        foundStartTime: l.foundStartTime,
        foundDate: l.foundDate,
        venueChanged: l.venueChanged,
        remarks: l.remarks,
        isCompensation: l.isCompensation,
        compensationFor: l.compensationFor,
      );
}

/// The store the whole monitor app uses. Living on this field keeps the screens
/// free of wiring and lets tests swap in [InMemoryPatrolStore].
PatrolStore patrolStore = SqflitePatrolStore.instance;