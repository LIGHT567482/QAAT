import '../net/net.dart';

/// Lecturer-attendance views for the coordinator — same endpoint family the web
/// dashboards read, from the ONE app the coordinator already carries.
///
/// Two independent records of the same lectures, deliberately NEVER merged (see the
/// backend handlers' comments):
///   • Coordinator record  — what the lecturer started/ended in the session (contact hours)
///     → `lecturer_attendance_logs` via /dashboard/lecturer-attendance[/summary]
///   • QA monitor record   — what a monitor saw on walking into the room
///     → `lecturer_patrol_logs` via /dashboard/lecturer-attendance/patrol
/// The paradox where they disagree is the finding QA exists to surface, so the Flutter
/// screen keeps them on separate tabs exactly like the web dossiers.
///
/// The manual taught/not-taught record (a lecture with no timetable slot) shares the
/// patrol family's endpoints; it stamps `X-Device-Fingerprint` there because the server
/// records which handset filed the observation.
class LecturerAttendanceClient {
  LecturerAttendanceClient({this.fingerprint});

  /// The `X-Device-Fingerprint` the server records against patrol-family writes.
  final String? fingerprint;

  /// GET /api/v1/dashboard/lecturer-attendance/summary — per-lecturer aggregates over
  /// the coordinator's own session logs.
  Future<List<LecturerSummary>> summary(String token) async {
    final o = await Net.getJson('/api/v1/dashboard/lecturer-attendance/summary', token: token)
        as List;
    return o.map((e) => LecturerSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// GET /api/v1/dashboard/lecturer-attendance — every session log, newest first.
  Future<List<AttendanceLog>> logs(String token) async {
    final o = await Net.getJson('/api/v1/dashboard/lecturer-attendance', token: token) as List;
    return o.map((e) => AttendanceLog.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// GET /api/v1/dashboard/lecturer-attendance/patrol — QA monitor summary + every
  /// visit, optionally filtered to a `from`/`to` date range (YYYY-MM-DD inclusive).
  Future<PatrolAttendance> patrol(String token, {String from = '', String to = ''}) async {
    final q = <String, String>{
      if (from.isNotEmpty) 'from': from,
      if (to.isNotEmpty) 'to': to,
    };
    final path = q.isEmpty
        ? '/api/v1/dashboard/lecturer-attendance/patrol'
        : '/api/v1/dashboard/lecturer-attendance/patrol?${Uri(queryParameters: q).query}';
    final o = await Net.getJson(path, token: token) as Map<String, dynamic>;
    return PatrolAttendance(
      summary: (o['summary'] as List? ?? [])
          .map((e) => PatrolSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
      visits: (o['visits'] as List? ?? [])
          .map((e) => PatrolVisit.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// GET /api/v1/patrol/reference — the pick-lists behind the manual form, in ONE call
  /// so the form cannot half-load on a weak connection. Offline-safe: an empty list is
  /// returned rather than thrown, matching the Android phone's corridor behaviour.
  Future<PatrolReference> reference(String token) async {
    try {
      final o = await Net.getJson('/api/v1/patrol/reference',
              token: token, fingerprint: fingerprint)
          as Map<String, dynamic>;
      return PatrolReference.fromJson(o);
    } on NetFailure {
      return const PatrolReference();
    }
  }

  /// POST /api/v1/patrol/manual — file a lecture that is not on the timetable.
  ///
  /// Unlike a tick, this is sent immediately rather than queued: the coordinator is
  /// describing a lecture from scratch, and holding that in a local queue means the one
  /// record nobody else has is also the one most likely to be lost with the phone.
  /// Returns the server's message on refusal so the form can say WHICH field it wants.
  /// Returns null on success.
  Future<String?> manual(String token, ManualEntry e) async {
    final body = e.toJson();
    try {
      await Net.postJson('/api/v1/patrol/manual',
          token: token, fingerprint: fingerprint, body: body);
      return null;
    } on NetFailure catch (f) {
      return f.message;
    }
  }
}

/// One entry of a pick-list. `id` is what the server keys on, `label` what the
/// coordinator reads, `extra` a second fact shown under the label (a department, a
/// college).
class RefItem {
  const RefItem(this.id, this.label, [this.extra = '']);
  final String id;
  final String label;
  final String extra;
}

/// Everything the manual form offers to pick from, fetched in one call.
///
/// Maps mirror the Kotlin `PatrolReference`: a picked unit brings its class/group and
/// college ([unitDefaults], [unitDepartments]) and a picked lecturer brings his home
/// college ([lecturerSchools]) and department, so the coordinator is not asked to retype
/// what the registry already knows.
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

  final List<RefItem> rooms;
  final List<RefItem> units;
  final List<RefItem> lecturers;
  final List<String> schools;

  /// Each entry `extra` is the college it hangs under, so picking one fills both.
  final List<RefItem> departments;

  /// staff_id → the lecturer's home college.
  final Map<String, String> lecturerSchools;

  /// unit_id → (classGroup, school) the curriculum already knows.
  final Map<String, (String, String)> unitDefaults;

  /// unit_id → the department that owns it.
  final Map<String, String> unitDepartments;

  factory PatrolReference.fromJson(Map<String, dynamic> o) {
    List<RefItem> items(String key, String idField, String labelField, String extraField) =>
        ((o[key] as List?) ?? []).map((x) {
          final m = x as Map<String, dynamic>;
          return RefItem(
            (m[idField] as String? ?? '').trim(),
            ((m[labelField] as String? ?? '')).trim(),
            extraField.isEmpty ? '' : (m[extraField] as String? ?? ''),
          );
        }).toList();

    final rooms = items('rooms', 'venue_id', 'name', 'building');
    final units = items('units', 'unit_id', 'unit_name', 'course_id');
    final lecturers = items('lecturers', 'staff_id', 'full_name', 'department');
    final departments = items('departments', 'name', 'name', 'school');

    final lecturerSchools = <String, String>{};
    for (final m in (o['lecturers'] as List? ?? [])) {
      final x = m as Map<String, dynamic>;
      final id = (x['staff_id'] as String? ?? '').trim();
      if (id.isNotEmpty) lecturerSchools[id] = (x['school'] as String? ?? '');
    }

    final unitDefaults = <String, (String, String)>{};
    final unitDepartments = <String, String>{};
    for (final m in (o['units'] as List? ?? [])) {
      final x = m as Map<String, dynamic>;
      final id = (x['unit_id'] as String? ?? '').trim();
      if (id.isNotEmpty) {
        unitDefaults[id] = (
          (x['class_group'] as String? ?? '').trim(),
          (x['school'] as String? ?? '').trim(),
        );
        unitDepartments[id] = (x['department'] as String? ?? '').trim();
      }
    }

    return PatrolReference(
      rooms: rooms,
      units: units,
      lecturers: lecturers,
      schools: ((o['schools'] as List?) ?? []).map((s) => '$s').toList(),
      departments: departments,
      lecturerSchools: lecturerSchools,
      unitDefaults: unitDefaults,
      unitDepartments: unitDepartments,
    );
  }
}

/// Per-lecturer rollup over `lecturer_attendance_logs`.
class LecturerSummary {
  const LecturerSummary({
    required this.lecturerId,
    required this.lecturerName,
    required this.staffId,
    required this.department,
    required this.email,
    required this.totalSessions,
    required this.totalContactHours,
    required this.avgContactHours,
    required this.lastSessionDate,
  });

  final String lecturerId;
  final String lecturerName;
  final String staffId;
  final String department;
  final String email;
  final int totalSessions;
  final double totalContactHours;
  final double avgContactHours;
  final String lastSessionDate;

  factory LecturerSummary.fromJson(Map<String, dynamic> o) => LecturerSummary(
        lecturerId: o['lecturer_id'] as String? ?? '',
        lecturerName: o['lecturer_name'] as String? ?? '',
        staffId: o['staff_id'] as String? ?? '',
        department: o['department'] as String? ?? '',
        email: o['email'] as String? ?? '',
        totalSessions: (o['total_sessions'] as num? ?? 0).toInt(),
        totalContactHours: (o['total_contact_hours'] as num? ?? 0).toDouble(),
        avgContactHours: (o['avg_contact_hours'] as num? ?? 0).toDouble(),
        lastSessionDate: o['last_session_date'] as String? ?? '',
      );
}

/// One row of `lecturer_attendance_logs` — proof-of-presence from the session itself.
class AttendanceLog {
  const AttendanceLog({
    required this.logId,
    required this.lecturerId,
    required this.lecturerName,
    required this.department,
    required this.unitId,
    required this.unitName,
    required this.sessionDate,
    required this.gateOpenTime,
    required this.gateCloseTime,
    required this.contactHours,
    required this.sessionStatus,
    required this.studentsAttended,
    required this.classGroup,
    required this.qaMonitor,
    required this.qaMonitorStaffId,
    required this.isCompensation,
    required this.compensationFor,
    required this.room,
    required this.roomIsProvision,
    required this.provisionNote,
    required this.unscheduled,
    required this.deliveryMode,
  });

  final String logId;
  final String lecturerId;
  final String lecturerName;
  final String department;
  final String unitId;
  final String unitName;
  final String sessionDate;
  final String gateOpenTime;
  final String gateCloseTime;
  final double contactHours;
  final String sessionStatus;
  final int studentsAttended;
  final String classGroup;
  final String qaMonitor;
  final String qaMonitorStaffId;
  final bool isCompensation;
  final String compensationFor;
  final String room;
  final bool roomIsProvision;
  final String provisionNote;
  final bool unscheduled;
  final String deliveryMode;

  factory AttendanceLog.fromJson(Map<String, dynamic> o) => AttendanceLog(
        logId: o['log_id'] as String? ?? '',
        lecturerId: o['lecturer_id'] as String? ?? '',
        lecturerName: o['lecturer_name'] as String? ?? '',
        department: o['department'] as String? ?? '',
        unitId: o['unit_id'] as String? ?? '',
        unitName: o['unit_name'] as String? ?? '',
        sessionDate: o['session_date'] as String? ?? '',
        gateOpenTime: o['gate_open_time'] as String? ?? '',
        gateCloseTime: o['gate_close_time'] as String? ?? '',
        contactHours: (o['contact_hours'] as num? ?? 0).toDouble(),
        sessionStatus: o['session_status'] as String? ?? '',
        studentsAttended: (o['students_attended'] as num? ?? 0).toInt(),
        classGroup: o['class_group'] as String? ?? '',
        qaMonitor: o['qa_monitor'] as String? ?? '',
        qaMonitorStaffId: o['qa_monitor_staff_id'] as String? ?? '',
        isCompensation: o['is_compensation'] as bool? ?? false,
        compensationFor: o['compensation_for'] as String? ?? '',
        room: o['room'] as String? ?? '',
        roomIsProvision: o['room_is_provision'] as bool? ?? false,
        provisionNote: o['provision_note'] as String? ?? '',
        unscheduled: o['unscheduled'] as bool? ?? false,
        deliveryMode: o['delivery_mode'] as String? ?? 'IN_PERSON',
      );
}

/// Per-lecturer rollup over `lecturer_patrol_logs` (the QA monitor's round).
class PatrolSummary {
  const PatrolSummary({
    required this.lecturerId,
    required this.lecturerName,
    required this.department,
    required this.school,
    required this.patrolled,
    required this.taught,
    required this.missed,
    required this.rate,
    required this.lastPatrolDate,
  });

  final String lecturerId;
  final String lecturerName;
  final String department;
  final String school;
  final int patrolled;
  final int taught;
  final int missed;
  final double rate;
  final String lastPatrolDate;

  factory PatrolSummary.fromJson(Map<String, dynamic> o) => PatrolSummary(
        lecturerId: o['lecturer_id'] as String? ?? '',
        lecturerName: o['lecturer_name'] as String? ?? '',
        department: o['department'] as String? ?? '',
        school: o['school'] as String? ?? '',
        patrolled: (o['patrolled'] as num? ?? 0).toInt(),
        taught: (o['taught'] as num? ?? 0).toInt(),
        missed: (o['missed'] as num? ?? 0).toInt(),
        rate: (o['rate'] as num? ?? 0).toDouble(),
        lastPatrolDate: o['last_patrol_date'] as String? ?? '',
      );
}

/// One room visit by a QA monitor — the second, independent witness to a lecture.
class PatrolVisit {
  const PatrolVisit({
    required this.patrolId,
    required this.lecturerId,
    required this.lecturerName,
    required this.unitId,
    required this.unitName,
    required this.room,
    required this.sessionDate,
    required this.scheduledTime,
    required this.taught,
    required this.patrollerName,
    required this.patrollerStaffId,
    required this.qaMonitor,
    required this.qaMonitorStaffId,
    required this.takenAt,
    required this.classGroup,
    required this.studentsAttended,
    required this.isCompensation,
    required this.compensationFor,
    required this.entryMethod,
    required this.school,
  });

  final String patrolId;
  final String lecturerId;
  final String lecturerName;
  final String unitId;
  final String unitName;
  final String room;
  final String sessionDate;
  final String scheduledTime;
  final bool taught;
  final String patrollerName;
  final String patrollerStaffId;
  final String qaMonitor;
  final String qaMonitorStaffId;
  final String takenAt;
  final String classGroup;
  final int studentsAttended;
  final bool isCompensation;
  final String compensationFor;
  final String entryMethod;
  final String school;

  factory PatrolVisit.fromJson(Map<String, dynamic> o) => PatrolVisit(
        patrolId: o['patrol_id'] as String? ?? '',
        lecturerId: o['lecturer_id'] as String? ?? '',
        lecturerName: o['lecturer_name'] as String? ?? '',
        unitId: o['unit_id'] as String? ?? '',
        unitName: o['unit_name'] as String? ?? '',
        room: o['room'] as String? ?? '',
        sessionDate: o['session_date'] as String? ?? '',
        scheduledTime: o['scheduled_time'] as String? ?? '',
        taught: o['taught'] as bool? ?? false,
        patrollerName: o['patroller_name'] as String? ?? '',
        patrollerStaffId: o['patroller_staff_id'] as String? ?? '',
        qaMonitor: o['qa_monitor'] as String? ?? '',
        qaMonitorStaffId: o['qa_monitor_staff_id'] as String? ?? '',
        takenAt: o['taken_at'] as String? ?? '',
        classGroup: o['class_group'] as String? ?? '',
        studentsAttended: (o['students_attended'] as num? ?? 0).toInt(),
        isCompensation: o['is_compensation'] as bool? ?? false,
        compensationFor: o['compensation_for'] as String? ?? '',
        entryMethod: o['entry_method'] as String? ?? 'PATROL',
        school: o['school'] as String? ?? '',
      );
}

/// The QA monitor record page: per-lecturer rollup + the flat visit list.
class PatrolAttendance {
  const PatrolAttendance({required this.summary, required this.visits});
  final List<PatrolSummary> summary;
  final List<PatrolVisit> visits;
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

  Map<String, dynamic> toJson() => {
        'unit_id': unitId,
        'unit_name': unitName,
        'class_group': classGroup,
        'school': school,
        'department': department,
      };
}

/// What the coordinator saw, for a lecture with nothing on the timetable to tick.
class ManualEntry {
  ManualEntry({
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

  /// When the lecture BEGAN and when it was due to END, both HH:MM.
  final String timeOfDay;
  final String endTime;
  final bool taught;
  final String remarks;
  final bool isCompensation;

  /// The date AND START TIME of the lecture being made good, "YYYY-MM-DD HH:MM".
  /// Required whenever [isCompensation] is set — the server refuses the record without it.
  final String compensationForAt;

  /// The other unit codes this same hour delivered.
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
        'also_units': alsoUnits.map((u) => u.toJson()).toList(),
      };
}