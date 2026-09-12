/// The QA monitor round's data shapes — a faithful mirror of the native
/// coordinator-android entities (`PatrolSlotEntity`, `PatrolLogEntity`,
/// `OfficePersonEntity`, `OfficeVisitEntity`) and the patrol API DTOs, so the
/// offline queue stores exactly what the gateway's `/api/v1/patrol/*` endpoints
/// expect and returns.
library;

/// One timetabled lecture the monitor can tick. The whole week is cached, so the
/// offline search narrows [SlotsStore.patrolSlotsForDay] by today's day-of-week.
class PatrolSlot {
  const PatrolSlot({
    required this.unitId,
    required this.unitName,
    required this.courseCode,
    required this.lecturerStaffId,
    required this.lecturerName,
    required this.room,
    required this.dayOfWeek,
    required this.startTime,
    this.durationMinutes = 60,
    this.offeringId = '',
    this.cohort = '',
    this.alsoHere = '',
  });

  factory PatrolSlot.fromJson(Map<String, dynamic> o) {
    final uid = ((o['unit_id'] ?? '') as String);
    return PatrolSlot(
      unitId: uid,
      unitName: ((o['unit_name'] ?? uid) as String),
      courseCode: ((o['course_code'] ?? '') as String),
      lecturerStaffId: ((o['lecturer_staff_id'] ?? '') as String),
      lecturerName: ((o['lecturer_name'] ?? '') as String),
      room: ((o['room'] ?? '') as String),
      dayOfWeek: ((o['day_of_week'] ?? 0) as num).toInt(),
      startTime: ((o['start_time'] ?? '') as String),
      durationMinutes: ((o['duration_minutes'] ?? 60) as num).toInt(),
      offeringId: ((o['offering_id'] ?? '') as String),
      cohort: ((o['cohort'] ?? '') as String),
      alsoHere: _alsoHereOf(o['also_here']),
    );
  }

  final String unitId;
  final String unitName;
  final String courseCode;
  final String lecturerStaffId;
  final String lecturerName;
  final String room;

  /// 1..7 — `DateTime.weekday` numbering, matching the server's `day_of_week`.
  final int dayOfWeek;
  final String startTime; // "HH:MM"
  final int durationMinutes;

  /// Which cohort's session this is. Part of the slot's identity — two intakes can
  /// run the same unit at the same hour in different rooms, and ticking one must
  /// never show the other as "already marked".
  final String offeringId;
  final String cohort;

  /// The OTHER unit codes delivered this same hour/room/lecturer, flattened to
  /// "CODE — Name · Cohort" joined by " | " (the server sends `also_here`).
  final String alsoHere;

  Map<String, Object?> toRow() => {
        'unit_id': unitId,
        'unit_name': unitName,
        'course_code': courseCode,
        'lecturer_staff_id': lecturerStaffId,
        'lecturer_name': lecturerName,
        'room': room,
        'day_of_week': dayOfWeek,
        'start_time': startTime,
        'duration_minutes': durationMinutes,
        'offering_id': offeringId,
        'cohort': cohort,
        'also_here': alsoHere,
      };

  /// `day` is `DateTime`, `time` "HH:MM" padded to width, `offeringId` — the same
  /// composite the server's `ux_patrol_logs_slot` keys on.
  static String key(String unitId, String time, String offeringId) =>
      '$unitId@$time#$offeringId';
}

/// One monitor observation, queued offline and uploaded via `POST /api/v1/patrol/sync`.
class PatrolLog {
  const PatrolLog({
    required this.id,
    required this.unitId,
    this.unitName = '',
    this.courseCode = '',
    required this.lecturerId,
    this.lecturerName = '',
    this.room = '',
    this.sessionDate = '',
    this.scheduledTime = '',
    required this.taught,
    this.takenAt = '',
    this.synced = false,
    this.offeringId = '',
    this.foundVenue = '',
    this.foundStartTime = '',
    this.foundDate = '',
    this.venueChanged = false,
    this.remarks = '',
    this.isCompensation = false,
    this.compensationFor = '',
  });

  final String id;
  final String unitId;
  final String unitName;
  final String courseCode;
  final String lecturerId; // lecturer staff id
  final String lecturerName;
  final String room;
  final String sessionDate; // YYYY-MM-DD
  final String scheduledTime; // HH:MM
  final bool taught;
  final String takenAt; // RFC3339
  final bool synced;
  final String offeringId;
  final String foundVenue;
  final String foundStartTime;
  final String foundDate;
  final bool venueChanged;
  final String remarks;
  final bool isCompensation;
  final String compensationFor;

  Map<String, Object?> toSyncJson() => {
        'unit_id': unitId,
        'unit_name': unitName,
        'course_code': courseCode,
        'lecturer_id': lecturerId,
        'lecturer_name': lecturerName,
        'room': room,
        'session_date': sessionDate,
        'scheduled_time': scheduledTime,
        'taught': taught,
        'taken_at': takenAt,
        'offering_id': offeringId,
        'found_venue': foundVenue,
        'found_start_time': foundStartTime,
        'found_date': foundDate,
        'venue_changed': venueChanged,
        'remarks': remarks,
        'is_compensation': isCompensation,
        'compensation_for': compensationFor,
      };
}

/// One employee, cached so the office round works with no signal.
class OfficePerson {
  const OfficePerson({
    required this.staffId,
    this.fullName = '',
    this.department = '',
    this.jobTitle = '',
    this.office = '',
  });

  final String staffId;
  final String fullName;
  final String department;
  final String jobTitle;

  /// What the registry thinks — the starting point, not the answer.
  final String office;
}

/// One office visit, queued offline and uploaded via `POST /api/v1/patrol/office/sync`.
class OfficeVisit {
  const OfficeVisit({
    required this.id,
    required this.staffId,
    this.employeeName = '',
    this.department = '',
    this.jobTitle = '',
    this.office = '',
    this.officeSource = 'TYPED',
    this.status = '',
    this.foundAt = '',
    this.remarks = '',
    this.visitDate = '',
    this.visitTime = '',
    this.capturedAt = '',
    this.synced = false,
  });

  /// Minted by the phone and it IS the server's primary key — a retried batch
  /// updates in place rather than filing the visit twice; a fresh id is a genuine
  /// second visit (absent in the morning, present in the afternoon).
  final String id;
  final String staffId;
  final String employeeName;
  final String department;
  final String jobTitle;
  final String office;
  final String officeSource; // REGISTRY | TYPED
  final String status; // AT_OFFICE | ELSEWHERE_ON_DUTY | ABSENT
  final String foundAt;
  final String remarks;
  final String visitDate; // YYYY-MM-DD
  final String visitTime; // HH:MM
  final String capturedAt; // RFC3339
  final bool synced;

  Map<String, Object?> toSyncJson() => {
        'visit_id': id,
        'staff_id': staffId,
        'office': office,
        'office_source': officeSource,
        'status': status,
        'found_at': foundAt,
        'remarks': remarks,
        'captured_at': capturedAt,
      };
}

// ── Manual-entry reference lists (GET /api/v1/patrol/reference) ──────────────

/// One entry of a pick-list. `id` is what the server keys on, `label` what the
/// monitor reads.
class RefItem {
  const RefItem(this.id, this.label, [this.extra = '']);
  final String id;
  final String label;
  final String extra;
}

/// The reference lists behind the manual form, fetched in ONE call. Mirrors the
/// native `PatrolReference`.
class PatrolReference {
  const PatrolReference({
    this.rooms = const [],
    this.units = const [],
    this.lecturers = const [],
    this.schools = const [],
    this.departments = const [],
    this.lecturerSchools = const {},
    this.unitDefaults = const {},
    this.unitDepartments = const {},
  });

  factory PatrolReference.fromJson(Map<String, dynamic> o) {
    List<dynamic> arr(String k) => o[k] as List? ?? const [];
    RefItem item(Map<String, dynamic> x,
            {String idKey = 'id', String labelKey = 'label', String? extraKey}) =>
        RefItem(
          '${x[idKey] ?? ''}',
          '${x[labelKey] ?? x[idKey] ?? ''}',
          extraKey == null ? '' : '${x[extraKey] ?? ''}',
        );

    final defaults = <String, (String, String)>{};
    final departments = <String, String>{};
    final units = arr('units').map((e) {
      final x = e as Map<String, dynamic>;
      final uid = '${x['unit_id'] ?? ''}';
      defaults[uid] =
          ('${x['class_group'] ?? ''}', '${x['school'] ?? ''}');
      departments[uid] = '${x['department'] ?? ''}';
      return RefItem(uid, '${x['unit_name'] ?? uid}',
          '${x['course_id'] ?? ''}');
    }).toList();

    final lecturerSchools = <String, String>{};
    final lecturers = arr('lecturers').map((e) {
      final x = e as Map<String, dynamic>;
      final sid = '${x['staff_id'] ?? ''}';
      lecturerSchools[sid] = '${x['school'] ?? ''}';
      return RefItem(sid, '${x['full_name'] ?? sid}',
          '${x['department'] ?? ''}');
    }).toList();

    return PatrolReference(
      rooms: arr('rooms')
          .map((e) => item(e as Map<String, dynamic>,
              idKey: 'venue_id', labelKey: 'name', extraKey: 'building'))
          .toList(),
      units: units,
      lecturers: lecturers,
      schools: arr('schools').map((s) => '$s').toList(),
      departments: arr('departments')
          .map((e) => item(e as Map<String, dynamic>,
              labelKey: 'name', extraKey: 'school'))
          .toList(),
      lecturerSchools: lecturerSchools,
      unitDefaults: defaults,
      unitDepartments: departments,
    );
  }

  final List<RefItem> rooms;
  final List<RefItem> units;
  final List<RefItem> lecturers;
  final List<String> schools;

  /// Department options, each knowing (`extra`) the college it hangs under.
  final List<RefItem> departments;

  /// staff_id → the lecturer's home college.
  final Map<String, String> lecturerSchools;

  /// unit_id → (class group, college) the curriculum already knows.
  final Map<String, (String, String)> unitDefaults;

  /// unit_id → the department that owns it.
  final Map<String, String> unitDepartments;
}

/// One extra course unit the same hour of teaching also delivered.
class ExtraUnit {
  const ExtraUnit({
    this.unitId = '',
    this.unitName = '',
    this.classGroup = '',
    this.school = '',
    this.department = '',
  });
  final String unitId;
  final String unitName;
  final String classGroup;
  final String school;
  final String department;

  ExtraUnit copyWith({
    String? unitId,
    String? unitName,
    String? classGroup,
    String? school,
    String? department,
  }) =>
      ExtraUnit(
        unitId: unitId ?? this.unitId,
        unitName: unitName ?? this.unitName,
        classGroup: classGroup ?? this.classGroup,
        school: school ?? this.school,
        department: department ?? this.department,
      );
}

/// What the monitor saw, for a lecture with nothing on the timetable to tick.
class ManualEntry {
  const ManualEntry({
    this.roomId = '',
    this.room = '',
    this.unitId = '',
    this.unitName = '',
    this.lecturerStaffId = '',
    this.lecturerName = '',
    this.classGroup = '',
    this.school = '',
    this.department = '',
    this.studentsCounted = 0,
    this.sessionDate = '',
    this.timeOfDay = '',
    this.endTime = '',
    this.taught = true,
    this.remarks = '',
    this.isCompensation = false,
    this.compensationForAt = '',
    this.alsoUnits = const [],
  });

  final String roomId;
  final String room;
  final String unitId;
  final String unitName;
  final String lecturerStaffId;
  final String lecturerName;
  final String classGroup;
  final String school;
  final String department;
  final int studentsCounted;
  final String sessionDate;
  final String timeOfDay;
  final String endTime;
  final bool taught;
  final String remarks;
  final bool isCompensation;

  /// "YYYY-MM-DD HH:MM" of the lecture being made good — required when
  /// `isCompensation` is set; the server refuses the record without it.
  final String compensationForAt;
  final List<ExtraUnit> alsoUnits;

  Map<String, dynamic> toJson() => {
        'room_id': roomId,
        'room': room,
        'unit_id': unitId,
        'unit_name': unitName,
        'lecturer_staff_id': lecturerStaffId,
        'lecturer_name': lecturerName,
        'class_group': classGroup,
        'school': school,
        'department': department,
        'students_counted': studentsCounted,
        'session_date': sessionDate,
        'time_of_day': timeOfDay,
        'end_time': endTime,
        'taught': taught,
        'remarks': remarks,
        'is_compensation': isCompensation,
        'compensation_for_at': compensationForAt,
        'also_units': alsoUnits
            .map((u) => {
                  'unit_id': u.unitId,
                  'unit_name': u.unitName,
                  'class_group': u.classGroup,
                  'school': u.school,
                  'department': u.department,
                })
            .toList(),
      };
}

/// Flatten the server's `also_here` array to the display string the card shows.
String _alsoHereOf(Object? raw) {
  if (raw is! List) return '';
  return raw
      .map((e) => e as Map<String, dynamic>)
      .map((u) {
        final code = '${u['unit_id'] ?? ''}';
        final name = '${u['unit_name'] ?? ''}';
        final cohort = '${u['cohort'] ?? ''}';
        final bits = [
          if (code.isNotEmpty) code,
          if (name.isNotEmpty && !name.toLowerCase().contains(code.toLowerCase())) name,
        ].join(' — ');
        final line = cohort.isEmpty ? bits : '$bits · $cohort';
        return line.isNotEmpty ? line : null;
      })
      .whereType<String>()
      .join(' | ');
}