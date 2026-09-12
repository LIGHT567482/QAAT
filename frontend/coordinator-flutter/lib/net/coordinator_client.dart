import 'net.dart';

/// One cohort of a course — the object a coordinator runs.
class CoordOffering {
  const CoordOffering({
    this.offeringId = '',
    this.courseId = '',
    this.courseName = '',
    this.sessionType = '',
    this.studyYear = 0,
    this.semester = 0,
    this.level = '',
    this.intake = '',
    this.school = '',
    this.department = '',
  });

  factory CoordOffering.fromJson(Map<String, dynamic> o) => CoordOffering(
        offeringId: (o['offering_id'] ?? '') as String,
        courseId: (o['course_id'] ?? '') as String,
        courseName: (o['course_name'] ?? '') as String,
        sessionType: (o['session_type'] ?? '') as String,
        studyYear: ((o['study_year'] ?? 0) as num).toInt(),
        semester: ((o['semester'] ?? 0) as num).toInt(),
        level: (o['level'] ?? '') as String,
        intake: (o['intake'] ?? '') as String,
        school: (o['school'] ?? '') as String,
        department: (o['department'] ?? '') as String,
      );

  final String offeringId;
  final String courseId;
  final String courseName;
  final String sessionType;
  final int studyYear;
  final int semester;
  final String level;
  final String intake;
  final String school;
  final String department;

  /// The one-line cohort label: "Course · SessionType · Year n · Sem n · level · intake".
  String get label => [
        courseName,
        sessionType,
        if (studyYear > 0) 'Year $studyYear',
        if (semester > 0) 'Sem $semester',
        level,
        intake,
      ].where((s) => s.isNotEmpty).join(' · ');
}

/// One unit of the coordinator's offering, either from the weekly `slots` grid or
/// the coarse `units` list (which carries year/semester but no room).
class CoordUnit {
  const CoordUnit({
    required this.unitId,
    required this.name,
    this.year = 0,
    this.semester = 0,
    this.dayOfWeek = 0,
    this.start = '',
    this.durationMin = 0,
    this.lecturers = '',
    this.room = '',
    this.lecturerPhone = '',
  });

  final String unitId;
  final String name;
  final int year;
  final int semester;
  final int dayOfWeek;
  final String start;
  final int durationMin;
  final String lecturers;
  final String room;
  final String lecturerPhone;

  bool get schedulable => dayOfWeek >= 1 && dayOfWeek <= 7 && start.isNotEmpty;
}

/// A student's row in the coordinator's cohort.
class CoordStudent {
  const CoordStudent({
    required this.studentId,
    required this.fullName,
    this.email = '',
    this.year = 1,
    this.semester = 1,
    this.academicYear = '',
    this.intake = '',
    this.status = 'ACTIVE',
  });

  factory CoordStudent.fromJson(Map<String, dynamic> o) => CoordStudent(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        email: (o['email'] ?? '') as String,
        year: ((o['current_year'] ?? 1) as num).toInt(),
        semester: ((o['semester'] ?? 1) as num).toInt(),
        academicYear: (o['academic_year'] ?? '') as String,
        intake: (o['intake_session'] ?? '') as String,
        status: (o['enrollment_status'] ?? 'ACTIVE') as String,
      );

  final String studentId;
  final String fullName;
  final String email;
  final int year;
  final int semester;
  final String academicYear;
  final String intake;
  final String status;
}

/// One student/unit attendance summary of `/coordinator/attendance`.
class AttendanceRow {
  const AttendanceRow({
    required this.studentId,
    required this.fullName,
    required this.unitId,
    required this.unitName,
    this.sessionsHeld = 0,
    this.sessionsAttended = 0,
    this.attendancePct = 0,
    this.threshold = 75,
  });

  factory AttendanceRow.fromJson(Map<String, dynamic> o) => AttendanceRow(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        sessionsHeld: ((o['sessions_held'] ?? 0) as num).toInt(),
        sessionsAttended: ((o['sessions_attended'] ?? 0) as num).toInt(),
        attendancePct: ((o['attendance_percentage'] ?? 0) as num).toDouble(),
        threshold: ((o['threshold'] ?? 75) as num).toInt(),
      );

  final String studentId;
  final String fullName;
  final String unitId;
  final String unitName;
  final int sessionsHeld;
  final int sessionsAttended;
  final double attendancePct;
  final int threshold;

  bool get belowThreshold => attendancePct < threshold;
}

/// A single roster line of a closed session.
class RosterRow {
  const RosterRow({
    required this.studentId,
    required this.fullName,
    this.status = 'ABSENT',
    this.checkinTime = '',
  });

  factory RosterRow.fromJson(Map<String, dynamic> o) => RosterRow(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        status: (o['status'] ?? 'ABSENT') as String,
        checkinTime: (o['checkin_time'] ?? '') as String,
      );

  final String studentId;
  final String fullName;
  final String status;
  final String checkinTime;

  bool get isPresent => status.toUpperCase() == 'PRESENT';
}

/// The last closed (synced) session's roster.
class LastRoster {
  const LastRoster({
    this.sessionId = '',
    this.unitName = '',
    this.date = '',
    this.closedAt = '',
    this.present = 0,
    this.total = 0,
    this.roster = const [],
  });

  factory LastRoster.fromJson(Map<String, dynamic> o) {
    final s = (o['session'] as Map<String, dynamic>?) ?? const {};
    return LastRoster(
      sessionId: (s['session_id'] ?? '') as String,
      unitName: (s['unit_name'] ?? '') as String,
      date: (s['session_date'] ?? '') as String,
      closedAt: (s['closed_at'] ?? '') as String,
      present: ((s['present'] ?? 0) as num).toInt(),
      total: ((s['total'] ?? 0) as num).toInt(),
      roster: ((o['roster'] ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(RosterRow.fromJson)
          .toList(),
    );
  }

  final String sessionId;
  final String unitName;
  final String date;
  final String closedAt;
  final int present;
  final int total;
  final List<RosterRow> roster;
}

/// One currently-live session of the coordinator (`/coordinator/active-sessions`).
class ActiveSession {
  const ActiveSession({
    required this.sessionId,
    required this.unitName,
    this.status = 'ACTIVE',
    this.gateOpenTime = '',
    this.windowEnd = '',
    this.presentCount = 0,
  });

  factory ActiveSession.fromJson(Map<String, dynamic> o) => ActiveSession(
        sessionId: (o['session_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        status: (o['status'] ?? 'ACTIVE') as String,
        gateOpenTime: (o['gate_open_time'] ?? '') as String,
        windowEnd: (o['checkin_window_end'] ?? '') as String,
        presentCount: ((o['present_count'] ?? 0) as num).toInt(),
      );

  final String sessionId;
  final String unitName;
  final String status;
  final String gateOpenTime;
  final String windowEnd;
  final int presentCount;

  bool get awaitingLecturer => status == 'PENDING_LECTURER';
}

/// One week's attendance-rate point of `/coordinator/trends`.
class TrendWeek {
  const TrendWeek({this.label = '', this.ratePct = 0, this.belowThreshold = false});
  factory TrendWeek.fromJson(Map<String, dynamic> o) => TrendWeek(
        label: (o['label'] ?? '') as String,
        ratePct: ((o['rate_pct'] ?? 0) as num).toDouble(),
        belowThreshold: (o['below_threshold'] ?? false) as bool,
      );

  final String label;
  final double ratePct;
  final bool belowThreshold;
}

/// The whole trend summary of `/coordinator/trends`.
class TrendSummary {
  const TrendSummary({
    this.threshold = 75,
    this.weeks = const [],
    this.currentWeekRate = 0,
    this.semesterAverage = 0,
    this.bestWeek,
    this.worstWeek,
    this.weeksBelow = 0,
    this.trend = 'STABLE',
  });

  factory TrendSummary.fromJson(Map<String, dynamic> o) {
    final best = o['best_week'];
    final worst = o['worst_week'];
    return TrendSummary(
      threshold: ((o['threshold'] ?? 75) as num).toInt(),
      weeks: ((o['weeks'] ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(TrendWeek.fromJson)
          .toList(),
      currentWeekRate: ((o['current_week_rate'] ?? 0) as num).toDouble(),
      semesterAverage: ((o['semester_average'] ?? 0) as num).toDouble(),
      bestWeek: best is Map<String, dynamic> ? TrendWeek.fromJson(best) : null,
      worstWeek: worst is Map<String, dynamic> ? TrendWeek.fromJson(worst) : null,
      weeksBelow: ((o['weeks_below'] ?? 0) as num).toInt(),
      trend: (o['trend'] ?? 'STABLE') as String,
    );
  }

  final int threshold;
  final List<TrendWeek> weeks;
  final double currentWeekRate;
  final double semesterAverage;
  final TrendWeek? bestWeek;
  final TrendWeek? worstWeek;
  final int weeksBelow;
  final String trend;
}

/// A standby delegation the coordinator issued (`/coordinator/standby`).
class Standby {
  const Standby({
    required this.id,
    required this.code,
    this.deputyReg = '',
    this.deputyName = '',
    this.expiresAt = '',
  });

  factory Standby.fromJson(Map<String, dynamic> o) => Standby(
        id: (o['delegation_id'] ?? '') as String,
        code: (o['code'] ?? '') as String,
        deputyReg: (o['deputy_reg'] ?? '') as String,
        deputyName: (o['deputy_name'] ?? '') as String,
        expiresAt: (o['expires_at'] ?? '') as String,
      );

  final String id;
  final String code;
  final String deputyReg;
  final String deputyName;
  final String expiresAt;
}

/// A lecturer the coordinator can write to (the composer's picker).
class CoordLecturer {
  const CoordLecturer({required this.lecturerId, required this.fullName});
  factory CoordLecturer.fromJson(Map<String, dynamic> o) => CoordLecturer(
        lecturerId: (o['lecturer_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
      );
  final String lecturerId;
  final String fullName;
}

/// One room of the institution's free-room check.
class FreeRoom {
  const FreeRoom({
    required this.venueId,
    required this.name,
    this.building = '',
    this.capacity = 0,
    this.school = '',
    this.free = true,
    this.occupiedBy = '',
    this.occupiedUntil = '',
    this.occupiedNote = '',
  });

  factory FreeRoom.fromJson(Map<String, dynamic> o) => FreeRoom(
        venueId: (o['venue_id'] ?? '') as String,
        name: ((o['name'] ?? '') as String).isNotEmpty
            ? (o['name'] ?? '') as String
            : (o['venue_id'] ?? '') as String,
        building: (o['building'] ?? '') as String,
        capacity: ((o['capacity'] ?? 0) as num).toInt(),
        school: (o['school'] ?? '') as String,
        free: (o['free'] ?? true) as bool,
        occupiedBy: (o['occupied_by'] ?? '') as String,
        occupiedUntil: (o['occupied_until'] ?? '') as String,
        occupiedNote: (o['occupied_note'] ?? '') as String,
      );

  final String venueId;
  final String name;
  final String building;
  final int capacity;
  final String school;
  final bool free;
  final String occupiedBy;
  final String occupiedUntil;
  final String occupiedNote;
}

/// A session created via `POST /api/v1/sessions/open` — the register the
/// coordinator then shows a code for. [studentCode] is the number students type;
/// [checkinCode] is the lecturer's rotating code.
class SessionOpened {
  const SessionOpened({
    required this.sessionId,
    this.studentCode = '',
    this.checkinCode = '',
    this.windowEnd = '',
  });

  final String sessionId;
  final String studentCode;
  final String checkinCode;
  final String windowEnd;
}

/// The result of opening a register (`POST /sessions/{id}/open-geo`).
class OpenedRegister {
  const OpenedRegister({
    required this.code,
    this.closesAt,
    this.hasLocation = false,
  });
  final String code;
  final String? closesAt;
  final bool hasLocation;
}

/// The coordinator dashboard data access over the shared gateway — a faithful port
/// of the native `DashboardClient` + `OpenRegisterClient` + `FreeRoomsClient`.
///
/// Every call returns empty/null on any failure (offline or refused); the UI shows
/// its last-loaded copy with the offline banner that already sits over every tab.
class CoordinatorClient {
  const CoordinatorClient();

  Future<CoordOverview?> overview(String token) async {
    if (token.isEmpty) return null;
    try {
      final o =
          await Net.getJson('/api/v1/coordinator/overview', token: token);
      if (o is! Map<String, dynamic>) return null;
      return CoordOverview.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<List<CoordStudent>> students(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson('/api/v1/coordinator/students', token: token);
      if (o is! List) return const [];
      return o
          .whereType<Map<String, dynamic>>()
          .map(CoordStudent.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<List<AttendanceRow>> attendance(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o =
          await Net.getJson('/api/v1/coordinator/attendance', token: token);
      if (o is! List) return const [];
      return o.whereType<Map<String, dynamic>>().map(AttendanceRow.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  Future<TrendSummary?> trends(String token) async {
    if (token.isEmpty) return null;
    try {
      final o = await Net.getJson('/api/v1/coordinator/trends', token: token);
      if (o is! Map<String, dynamic>) return null;
      return TrendSummary.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<LastRoster?> lastRoster(String token) async {
    if (token.isEmpty) return null;
    try {
      final o =
          await Net.getJson('/api/v1/coordinator/last-roster', token: token);
      if (o is! Map<String, dynamic>) return null;
      final session = o['session'];
      if (session == null) return null;
      return LastRoster.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<List<ActiveSession>> activeSessions(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o =
          await Net.getJson('/api/v1/coordinator/active-sessions', token: token);
      if (o is! Map<String, dynamic>) return const [];
      final sessions = o['sessions'];
      if (sessions is! List) return const [];
      return sessions
          .whereType<Map<String, dynamic>>()
          .map(ActiveSession.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<bool> closeSession(String token, String sessionId) async {
    if (token.isEmpty || sessionId.isEmpty) return false;
    try {
      await Net.postJson('/api/v1/sessions/$sessionId/close',
          token: token, body: const {});
      return true;
    } on Object {
      return false;
    }
  }

  /// POST /api/v1/sessions/{sessionId}/open-geo — opens the register and mints the
  /// code students type. [latitude]/[longitude] are optional: with no fix available
  /// the register opens on code + time window alone (deliberately weaker).
  Future<OpenedRegister?> openRegister(
    String token,
    String sessionId, {
    double? latitude,
    double? longitude,
    int openMinutes = 15,
  }) async {
    if (token.isEmpty || sessionId.isEmpty) return null;
    try {
      final o = await Net.postJson(
        '/api/v1/sessions/$sessionId/open-geo',
        token: token,
        body: {
          'latitude': ?latitude,
          'longitude': ?longitude,
          'open_minutes': openMinutes,
        },
      );
      if (o is! Map<String, dynamic>) return null;
      return OpenedRegister(
        code: (o['session_code'] ?? '') as String,
        closesAt: (o['closes_at'] ?? '') as String?,
        hasLocation: (o['has_location'] ?? false) as bool,
      );
    } on Object {
      return null;
    }
  }

  /// POST /api/v1/sessions/open — creates the ACTIVE session and mints the codes.
  ///
  /// Throws [NetFailure] on refusal so the screen can say WHY (a session already
  /// open for this coordinator, opening refused outside the tenant's daily
  /// window, an unknown unit). []provisionRoom] / [provisionNote] / [unscheduled]
  /// declare the room-and-schedule facts the QA round depends on: a provision
  /// room redirects the monitors before they walk to an empty hall.
  Future<SessionOpened> createSession(
    String token,
    String unitId, {
    String venueId = '',
    String? lecturerId,
    String sessionDate = '',
    bool roomIsProvision = false,
    String provisionNote = '',
    bool unscheduled = false,
  }) async {
    if (token.isEmpty || unitId.isEmpty) {
      throw NetFailure(401, 'NOT_SIGNED_IN', 'Not signed in');
    }
    final o = await Net.postJson(
      '/api/v1/sessions/open',
      token: token,
      body: {
        'unit_id': unitId,
        if (venueId.isNotEmpty) 'venue_id': venueId,
        if (lecturerId != null && lecturerId.isNotEmpty)
          'lecturer_id': lecturerId,
        if (sessionDate.isNotEmpty) 'session_date': sessionDate,
        'room_is_provision': roomIsProvision,
        'provision_note': provisionNote,
        'unscheduled': unscheduled,
      },
    );
    if (o is! Map<String, dynamic>) {
      throw NetFailure(502, '', 'The server returned nothing to open a session with.');
    }
    return SessionOpened(
      sessionId: (o['session_id'] ?? '') as String,
      studentCode: (o['student_code'] ?? '') as String,
      checkinCode: (o['checkin_code'] ?? '') as String,
      windowEnd: (o['checkin_window_end'] ?? '') as String,
    );
  }

  Future<List<Standby>> standby(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson('/api/v1/coordinator/standby', token: token);
      if (o is! List) return const [];
      return o.whereType<Map<String, dynamic>>().map(Standby.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  /// Issues a standby delegation for a genuine absence. Returns the server's own
  /// refusal (a human message) or null when the code was minted — the native
  /// `DashboardClient.issueStandby` contract, so the card can print WHY it refused.
  Future<String?> issueStandby(String token, String deputyReg) async {
    final reg = deputyReg.trim();
    if (token.isEmpty || reg.isEmpty) {
      return 'Enter the standby student\u2019s registration number';
    }
    try {
      final o = await Net.postJson('/api/v1/coordinator/standby',
          token: token, body: {'deputy_reg': reg});
      if (o is Map<String, dynamic>) {
        final m = o['message'];
        if (m is String && m.isNotEmpty) return m;
      }
      return null;
    } on NetFailure catch (e) {
      return e.message;
    } on Object {
      return 'Could not issue the standby code. Check your connection and try again.';
    }
  }

  /// Allows the account's session on the phone to be closed via the standby pilot.
  Future<bool> revokeStandby(String token, String id) async {
    if (token.isEmpty || id.isEmpty) return false;
    try {
      await Net.postJson('/api/v1/coordinator/standby/$id/revoke',
          token: token, body: const {});
      return true;
    } on Object {
      return false;
    }
  }

  Future<List<CoordLecturer>> lecturers(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o =
          await Net.getJson('/api/v1/coordinator/lecturers', token: token);
      if (o is! List) return const [];
      return o.whereType<Map<String, dynamic>>().map(CoordLecturer.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  /// GET /api/v1/rooms/free?minutes=… — every room checked against the timetable
  /// and live sessions. Needs signal; a cached answer would send two classes to one room.
  Future<List<FreeRoom>> freeRooms(String token, {int minutes = 60}) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson(
          '/api/v1/rooms/free?minutes=$minutes', token: token);
      if (o is! Map<String, dynamic>) return const [];
      final rooms = o['rooms'];
      if (rooms is! List) return const [];
      return rooms.whereType<Map<String, dynamic>>().map(FreeRoom.fromJson).toList();
    } on Object {
      return const [];
    }
  }
}

/// The parsed `/coordinator/overview` body: the offering plus both the coarse `units`
/// and the weekly `slots` grid. Prefer `slots` for the timetable, `units` for year/sem.
class CoordOverview {
  const CoordOverview({this.offering, this.units = const [], this.slots = const []});

  factory CoordOverview.fromJson(Map<String, dynamic> o) {
    final offering = o['offering'];
    return CoordOverview(
      offering: offering is Map<String, dynamic>
          ? CoordOffering.fromJson(offering)
          : null,
      units: ((o['units'] ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(_coarseUnit)
          .toList(),
      slots: ((o['slots'] ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(_slotUnit)
          .toList(),
    );
  }

  final CoordOffering? offering;
  final List<CoordUnit> units;
  final List<CoordUnit> slots;

  /// The units to render: the weekly grid when it has anything, else the coarse list.
  List<CoordUnit> get displayUnits => slots.isNotEmpty ? slots : units;

  static CoordUnit _coarseUnit(Map<String, dynamic> o) => CoordUnit(
        unitId: (o['unit_id'] ?? '') as String,
        name: (o['name'] ?? '') as String,
        year: ((o['year'] ?? 0) as num).toInt(),
        semester: ((o['semester'] ?? 0) as num).toInt(),
        dayOfWeek: ((o['day_of_week'] ?? 0) as num).toInt(),
        start: (o['session_start'] ?? '') as String,
        durationMin: ((o['session_duration_minutes'] ?? 0) as num).toInt(),
        lecturers: (o['lecturers'] ?? '') as String,
      );

  static CoordUnit _slotUnit(Map<String, dynamic> o) => CoordUnit(
        unitId: (o['unit_id'] ?? '') as String,
        name: (o['unit_name'] ?? '') as String,
        dayOfWeek: ((o['day_of_week'] ?? 0) as num).toInt(),
        start: (o['start_time'] ?? '') as String,
        durationMin: ((o['duration_minutes'] ?? 0) as num).toInt(),
        room: (o['room'] ?? '') as String,
        lecturers: (o['lecturer_name'] ?? '') as String,
        lecturerPhone: (o['lecturer_phone'] ?? '') as String,
      );
}