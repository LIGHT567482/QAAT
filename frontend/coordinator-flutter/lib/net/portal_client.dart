import 'dart:convert';

import 'net.dart';

/// One unit in a lecturer's own-teaching roster (`/lecturer-portal/overview`).
class LecturerUnit {
  const LecturerUnit({
    required this.unitId,
    required this.name,
    this.year = 1,
    this.semester = 1,
    this.courseId = '',
    this.courseName = '',
  });

  factory LecturerUnit.fromJson(Map<String, dynamic> o) => LecturerUnit(
        unitId: (o['unit_id'] ?? '') as String,
        name: (o['name'] ?? '') as String,
        year: ((o['year'] ?? 1) as num).toInt(),
        semester: ((o['semester'] ?? 1) as num).toInt(),
        courseId: (o['course_id'] ?? '') as String,
        courseName: (o['course_name'] ?? '') as String,
      );

  final String unitId;
  final String name;
  final int year;
  final int semester;
  final String courseId;
  final String courseName;
}

/// A session row within one unit's attendance matrix.
class UnitSession {
  const UnitSession({
    required this.sessionId,
    required this.date,
    required this.coordinator,
  });

  factory UnitSession.fromJson(Map<String, dynamic> o) => UnitSession(
        sessionId: (o['session_id'] ?? '') as String,
        date: (o['session_date'] ?? '') as String,
        coordinator: (o['coordinator_name'] ?? '') as String,
      );

  final String sessionId;
  final String date;
  final String coordinator;
}

/// One student's row in the attendance matrix (per-session present flags).
class MatrixStudent {
  const MatrixStudent({
    required this.studentId,
    required this.fullName,
    required this.present,
  });

  factory MatrixStudent.fromJson(Map<String, dynamic> o) => MatrixStudent(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        present: ((o['present'] ?? const []) as List)
            .map((b) => b == true)
            .toList(),
      );

  final String studentId;
  final String fullName;
  final List<bool> present;
}

/// The lecturer's own-unit attendance matrix (`/lecturer-portal/attendance`).
class UnitAttendance {
  const UnitAttendance({
    required this.unitId,
    required this.sessions,
    required this.students,
  });

  factory UnitAttendance.fromJson(Map<String, dynamic> o) => UnitAttendance(
        unitId: (o['unit_id'] ?? '') as String,
        sessions: ((o['sessions'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(UnitSession.fromJson)
            .toList(),
        students: ((o['students'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(MatrixStudent.fromJson)
            .toList(),
      );

  final String unitId;
  final List<UnitSession> sessions;
  final List<MatrixStudent> students;
}

/// One unit row in the student's own progress summary (`/student/progress`).
class StudentProgressUnit {
  const StudentProgressUnit({
    required this.unitId,
    required this.unitName,
    this.sessionsHeld = 0,
    this.sessionsAttended = 0,
    this.attendancePct = 0,
    this.threshold = 75,
    this.status = '',
    this.deficitSessions,
  });

  factory StudentProgressUnit.fromJson(Map<String, dynamic> o) =>
      StudentProgressUnit(
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        sessionsHeld: ((o['sessions_held'] ?? 0) as num).toInt(),
        sessionsAttended: ((o['sessions_attended'] ?? 0) as num).toInt(),
        attendancePct: ((o['attendance_percentage'] ?? 0) as num).toDouble(),
        threshold: ((o['threshold'] ?? 75) as num).toInt(),
        status: (o['status'] ?? '') as String,
        deficitSessions: (o['deficit_sessions'] as num?)?.toInt(),
      );

  final String unitId;
  final String unitName;
  final int sessionsHeld;
  final int sessionsAttended;
  final double attendancePct;
  final int threshold;
  final String status;
  final int? deficitSessions;
}

/// The full student progress payload.
class StudentProgress {
  const StudentProgress({
    required this.regNo,
    required this.fullName,
    this.institution = '',
    this.school = '',
    this.department = '',
    this.academicYear = '',
    this.semester = 1,
    this.units = const [],
  });

  factory StudentProgress.fromJson(Map<String, dynamic> o) => StudentProgress(
        regNo: (o['reg'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        institution: (o['institution'] ?? '') as String,
        school: (o['school'] ?? '') as String,
        department: (o['department'] ?? '') as String,
        academicYear: (o['academic_year'] ?? '') as String,
        semester: ((o['semester'] ?? 1) as num).toInt(),
        units: ((o['units'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(StudentProgressUnit.fromJson)
            .toList(),
      );

  final String regNo;
  final String fullName;
  final String institution;
  final String school;
  final String department;
  final String academicYear;
  final int semester;
  final List<StudentProgressUnit> units;
}

/// Directory entry for the monitor composer's one-coordinator picker.
class CoordinatorEntry {
  const CoordinatorEntry({
    required this.userId,
    required this.fullName,
    this.department = '',
  });

  factory CoordinatorEntry.fromJson(Map<String, dynamic> o) => CoordinatorEntry(
        userId: (o['user_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        department: (o['department'] ?? '') as String,
      );

  final String userId;
  final String fullName;
  final String department;
}

/// The tenant's monitor-add-administrator switch.
class MonitorAddAdminsStatus {
  const MonitorAddAdminsStatus({this.enabled = false, this.defaultPassword = ''});
  factory MonitorAddAdminsStatus.fromJson(Map<String, dynamic> o) =>
      MonitorAddAdminsStatus(
        enabled: (o['enabled'] ?? false) as bool,
        defaultPassword: (o['default_password'] ?? '') as String,
      );
  final bool enabled;
  final String defaultPassword;
}

/// Read-only data access for the in-app lecturer and student dashboards, plus the
/// small directories the monitor composer and offices round need. These ride the
/// same cloud gateway as everything else; the portal endpoints are passwordless
/// by staff-id / reg-no (the same model as the web portals), so the dashboard
/// passes the signed-in identifier rather than a token. Offline, each returns an
/// empty/absent result and the dashboard shows its last-loaded copy with the
/// banner that already sits over every tab.
class PortalClient {
  const PortalClient();

  static const String _org = 'kiu';

  Future<List<LecturerUnit>> lecturerOverview(String? token, String staffId) async {
    if (staffId.isEmpty) return const [];
    try {
      final o = await _get('/api/v1/lecturer-portal/overview'
          '?staff_id=${Uri.encodeQueryComponent(staffId)}'
          '&org=$_org', token);
      if (o is! Map<String, dynamic>) return const [];
      final raw = (o['units'] ?? const []) as List;
      return raw
          .whereType<Map<String, dynamic>>()
          .map(LecturerUnit.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<UnitAttendance?> lecturerUnitAttendance(
      String? token, String staffId, String unitId) async {
    if (staffId.isEmpty || unitId.isEmpty) return null;
    try {
      final o = await _get('/api/v1/lecturer-portal/attendance'
          '?staff_id=${Uri.encodeQueryComponent(staffId)}'
          '&org=$_org'
          '&unit_id=${Uri.encodeQueryComponent(unitId)}', token);
      if (o is! Map<String, dynamic>) return null;
      return UnitAttendance.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<StudentProgress?> studentProgress(String? token, String regNo) async {
    if (regNo.isEmpty) return null;
    try {
      final o = await _get('/api/v1/student/progress'
          '?reg=${Uri.encodeQueryComponent(regNo)}', token);
      if (o is! Map<String, dynamic>) return null;
      final p = StudentProgress.fromJson(o);
      if (p.regNo.isEmpty && regNo.isNotEmpty) {
        return StudentProgress(regNo: regNo, fullName: p.fullName, units: p.units);
      }
      return p;
    } on Object {
      return null;
    }
  }

  /// GET /api/v1/patrol/coordinators — the one-coordinator picker of the monitor
  /// composer. Null on failure (offline), empty on an institution with none.
  Future<List<CoordinatorEntry>?> patrolCoordinators(String token) async {
    try {
      final o = await Net.getJson('/api/v1/patrol/coordinators', token: token);
      if (o is! List) return null;
      return o
          .whereType<Map<String, dynamic>>()
          .map(CoordinatorEntry.fromJson)
          .toList();
    } on Object {
      return null;
    }
  }

  /// GET /api/v1/patrol/office/can-add-admins — is the institution allowing a
  /// monitor to create an administrator from the round? Honors the tenant switch.
  Future<MonitorAddAdminsStatus?> canMonitorAddAdmins(String token) async {
    try {
      final o = await Net.getJson('/api/v1/patrol/office/can-add-admins',
          token: token,
          fingerprint: null);
      if (o is! Map<String, dynamic>) return null;
      return MonitorAddAdminsStatus.fromJson(o);
    } on Object {
      return null;
    }
  }

  /// POST /api/v1/patrol/office/add-admin — the add-only provisioner. Returns the
  /// server's message (which carries the public first-login word) or an error the
  /// offices tab should show verbatim.
  Future<String> monitorAddAdmin(
      String token, String fullName, String email, String department) async {
    try {
      final o = await Net.postJson('/api/v1/patrol/office/add-admin',
          token: token,
          body: {
            'full_name': fullName,
            'email': email,
            if (department.trim().isNotEmpty) 'department': department,
          });
      if (o is Map<String, dynamic>) {
        final m = o['message'];
        if (m is String && m.isNotEmpty) return m;
        return 'Administrator created.';
      }
      return 'Administrator created.';
    } on NetFailure catch (e) {
      return e.message;
    } on Object {
      return "Couldn't reach the server. Check your connection and try again.";
    }
  }

  Future<dynamic> _get(String path, String? token) async {
    final r = await Net.retrying(() => Net.shared.get(
          Uri.parse(Net.baseUrl + path),
          headers: {
            if (token != null && token.isNotEmpty)
              'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NetFailure(r.statusCode, '', 'portal fetch failed (${r.statusCode})');
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }
}