import 'net.dart';

/// One unit of the lecturer's own teaching roster (`/lecturer/overview`).
class FromOverviewUnit {
  const FromOverviewUnit({required this.unitId, required this.name});
  factory FromOverviewUnit.fromJson(Map<String, dynamic> o) => FromOverviewUnit(
        unitId: (o['unit_id'] ?? '') as String,
        name: (o['name'] ?? '') as String,
      );
  final String unitId;
  final String name;
}

/// One roster line of the lecturer's Roster tab (`/lecturer/roster`).
class LectRosterRow {
  const LectRosterRow({
    required this.studentId,
    required this.fullName,
    this.unitId = '',
    this.unitName = '',
    this.cohort = '',
    this.courseName = '',
    this.level = '',
    this.attendedCount = 0,
    this.heldCount = 0,
    this.pct = 0,
  });

  factory LectRosterRow.fromJson(Map<String, dynamic> o) => LectRosterRow(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        cohort: (o['cohort'] ?? '') as String,
        courseName: (o['course_name'] ?? '') as String,
        level: (o['unit_level'] ?? '') as String,
        attendedCount: ((o['attended_count'] ?? 0) as num).toInt(),
        heldCount: ((o['held_count'] ?? 0) as num).toInt(),
        pct: ((o['pct'] ?? 0) as num).toDouble(),
      );

  final String studentId;
  final String fullName;
  final String unitId;
  final String unitName;
  final String cohort;
  final String courseName;
  final String level;
  final int attendedCount;
  final int heldCount;
  final double pct;
}

/// One session of the lecturer's Roster tab (`/lecturer/sessions`).
class LectSession {
  const LectSession({
    required this.sessionId,
    this.unitId = '',
    this.unitName = '',
    this.date = '',
    this.dayOfWeek = 0,
    this.cohort = '',
    this.status = '',
    this.present = 0,
    this.enrolled = 0,
  });

  factory LectSession.fromJson(Map<String, dynamic> o) => LectSession(
        sessionId: (o['session_id'] ?? '') as String,
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        date: (o['session_date'] ?? '') as String,
        dayOfWeek: ((o['day_of_week'] ?? 0) as num).toInt(),
        cohort: (o['cohort'] ?? '') as String,
        status: (o['status'] ?? '') as String,
        present: ((o['present_count'] ?? 0) as num).toInt(),
        enrolled: ((o['enrolled_count'] ?? 0) as num).toInt(),
      );

  final String sessionId;
  final String unitId;
  final String unitName;
  final String date;
  final int dayOfWeek;
  final String cohort;
  final String status;
  final int present;
  final int enrolled;
}

/// One student of a single session's roster (`/lecturer/sessions/{id}/students`).
class LectSessionStudent {
  const LectSessionStudent({
    required this.studentId,
    required this.fullName,
    this.present = false,
    this.checkinAt = '',
  });

  factory LectSessionStudent.fromJson(Map<String, dynamic> o) =>
      LectSessionStudent(
        studentId: (o['student_id'] ?? '') as String,
        fullName: (o['full_name'] ?? '') as String,
        present: (o['present'] ?? false) as bool,
        checkinAt: (o['checkin_at'] ?? '') as String,
      );

  final String studentId;
  final String fullName;
  final bool present;
  final String checkinAt;
}

/// One timetabled slot of the lecturer's week (`/lecturer/timetable`).
class LectSlot {
  const LectSlot({
    required this.unitId,
    this.offeringId = '',
    this.unitName = '',
    this.courseName = '',
    this.sessionType = '',
    this.level = '',
    this.intake = '',
    this.studyYear = 0,
    this.semester = 0,
    this.dayOfWeek = 0,
    this.startTime = '',
    this.durationMinutes = 60,
    this.room = '',
    this.building = '',
    this.deliveryMode = 'IN_PERSON',
    this.namedOnSlot = true,
    this.enrolled = 0,
  });

  factory LectSlot.fromJson(Map<String, dynamic> o) {
    final name = ((o['unit_name'] ?? '') as String).isNotEmpty
        ? (o['unit_name'] ?? '') as String
        : (o['unit_id'] ?? '') as String;
    return LectSlot(
      unitId: (o['unit_id'] ?? '') as String,
      offeringId: (o['offering_id'] ?? '') as String,
      unitName: name,
      courseName: (o['course_name'] ?? '') as String,
      sessionType: (o['session_type'] ?? '') as String,
      level: (o['level'] ?? '') as String,
      intake: (o['intake'] ?? '') as String,
      studyYear: ((o['study_year'] ?? 0) as num).toInt(),
      semester: ((o['semester'] ?? 0) as num).toInt(),
      dayOfWeek: ((o['day_of_week'] ?? 0) as num).toInt(),
      startTime: (o['start_time'] ?? '') as String,
      durationMinutes: ((o['duration_minutes'] ?? 60) as num).toInt(),
      room: (o['room'] ?? '') as String,
      building: (o['building'] ?? '') as String,
      deliveryMode: (o['delivery_mode'] ?? 'IN_PERSON') as String,
      namedOnSlot: (o['named_on_slot'] ?? true) as bool,
      enrolled: ((o['enrolled'] ?? 0) as num).toInt(),
    );
  }

  final String unitId;
  final String offeringId;
  final String unitName;
  final String courseName;
  final String sessionType;
  final String level;
  final String intake;
  final int studyYear;
  final int semester;
  final int dayOfWeek;
  final String startTime;
  final int durationMinutes;
  final String room;
  final String building;
  final String deliveryMode;
  final bool namedOnSlot;
  final int enrolled;

  bool get online => deliveryMode.toUpperCase() == 'ONLINE';

  /// "Day · Y2 S1 · August Intake" — the cohort a slot is taught to.
  String get cohort => [
        sessionType,
        if (studyYear > 0 && semester > 0) 'Y$studyYear S$semester',
        level,
        intake,
      ].where((s) => s.isNotEmpty).join(' · ');
}

/// One action-worthy event of the lecturer's month calendar (`/lecturer/calendar`).
class CalendarEvent {
  const CalendarEvent({
    this.date = '',
    this.unitId = '',
    this.unitName = '',
    this.startTime = '',
    this.durationMinutes = 0,
    this.room = '',
    this.held = false,
    this.status = '',
    this.enrolled = 0,
    this.present = 0,
    this.pct = 0,
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> o) => CalendarEvent(
        date: (o['date'] ?? '') as String,
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
        startTime: (o['start_time'] ?? '') as String,
        durationMinutes: ((o['duration_minutes'] ?? 0) as num).toInt(),
        room: (o['room'] ?? '') as String,
        held: (o['held'] ?? false) as bool,
        status: (o['status'] ?? '') as String,
        enrolled: ((o['enrolled'] ?? 0) as num).toInt(),
        present: ((o['present'] ?? 0) as num).toInt(),
        pct: ((o['pct'] ?? 0) as num).toDouble(),
      );

  final String date;
  final String unitId;
  final String unitName;
  final String startTime;
  final int durationMinutes;
  final String room;
  final bool held;
  final String status;
  final int enrolled;
  final int present;
  final double pct;
}

/// A unit filter option for the calendar (`/lecturer/calendar` → `units`).
class CalendarUnit {
  const CalendarUnit({required this.unitId, required this.unitName});
  factory CalendarUnit.fromJson(Map<String, dynamic> o) => CalendarUnit(
        unitId: (o['unit_id'] ?? '') as String,
        unitName: (o['unit_name'] ?? '') as String,
      );
  final String unitId;
  final String unitName;
}

/// The month page of `/lecturer/calendar`.
class LecturerCalendar {
  const LecturerCalendar({this.from = '', this.to = '', this.units = const [], this.events = const []});
  factory LecturerCalendar.fromJson(Map<String, dynamic> o) => LecturerCalendar(
        from: (o['from'] ?? '') as String,
        to: (o['to'] ?? '') as String,
        units: ((o['units'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(CalendarUnit.fromJson)
            .toList(),
        events: ((o['events'] ?? const []) as List)
            .whereType<Map<String, dynamic>>()
            .map(CalendarEvent.fromJson)
            .toList(),
      );
  final String from;
  final String to;
  final List<CalendarUnit> units;
  final List<CalendarEvent> events;
}

/// Someone the lecturer can write to (`/lecturer/recipients`).
class LecturerRecipient {
  const LecturerRecipient({
    required this.userId,
    required this.name,
    this.cohort = '',
    this.course = '',
  });
  final String userId;
  final String name;
  final String cohort;
  final String course;

  String get label => name.isNotEmpty ? name : userId;
}

/// One offline presence claim, minted on the phone and uploaded as a batch
/// (`POST /lecturer/presence-claims`). Claim ids are phone-minted; the server's
/// primary key rejects duplicates, so retrying after a timeout is always safe.
class PresenceClaim {
  const PresenceClaim({
    this.claimId = '',
    this.locationStatus = 'NO_FIX',
    this.capturedAt = '',
    this.sessionDate = '',
    this.unitId = '',
    this.unitName = '',
    this.room = '',
    this.dayOfWeek = 0,
    this.scheduledTime = '',
    this.matchKind = 'NONE',
    this.note = '',
    this.latitude,
    this.longitude,
    this.accuracyMetres,
    this.minutesFromStart,
  });

  Map<String, dynamic> toJson() => {
        'claim_id': claimId,
        'location_status': locationStatus,
        'captured_at': capturedAt,
        'session_date': sessionDate,
        'unit_id': unitId,
        'unit_name': unitName,
        'room': room,
        'day_of_week': dayOfWeek,
        'scheduled_time': scheduledTime,
        'match_kind': matchKind,
        'note': note,
        // The server reads an explicit JSON null as "no fix" — omit nothing here.
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_metres': accuracyMetres,
        'minutes_from_start': minutesFromStart,
      };

  final String claimId;
  final String locationStatus;
  final String capturedAt;
  final String sessionDate;
  final String unitId;
  final String unitName;
  final String room;
  final int dayOfWeek;
  final String scheduledTime;
  final String matchKind;
  final String note;
  final double? latitude;
  final double? longitude;
  final double? accuracyMetres;
  final int? minutesFromStart;
}

/// The online (distance/e-learning) class state (`/lecturer/online-class`).
class OnlineClassLive {
  const OnlineClassLive({
    this.sessionId = '',
    this.unitId = '',
    this.unitName = '',
    this.cohortLabel = '',
    this.studentCode = '',
    this.secondsRemaining = 0,
    this.checkinWindowEnd = '',
    this.present = 0,
    this.enrolled = 0,
    this.startedAt = '',
  });

  factory OnlineClassLive.fromJson(Map<String, dynamic> o) {
    final name = ((o['unit_name'] ?? '') as String).isNotEmpty
        ? (o['unit_name'] ?? '') as String
        : (o['unit_id'] ?? '') as String;
    return OnlineClassLive(
      sessionId: (o['session_id'] ?? '') as String,
      unitId: (o['unit_id'] ?? '') as String,
      unitName: name,
      cohortLabel: (o['cohort_label'] ?? '') as String,
      studentCode: (o['student_code'] ?? '') as String,
      secondsRemaining: ((o['seconds_remaining'] ?? 0) as num).toInt(),
      checkinWindowEnd: (o['checkin_window_end'] ?? '') as String,
      present: ((o['present'] ?? 0) as num).toInt(),
      enrolled: ((o['enrolled'] ?? 0) as num).toInt(),
      startedAt: (o['started_at'] ?? '') as String,
    );
  }

  final String sessionId;
  final String unitId;
  final String unitName;
  final String cohortLabel;
  final String studentCode;
  final int secondsRemaining;
  final String checkinWindowEnd;
  final int present;
  final int enrolled;
  final String startedAt;
}

/// The lecturer dashboard data access over the shared gateway — a faithful port of
/// the native `LecturerClient`, `LecturerTimetableClient`, `LecturerCalendarClient`,
/// `PresenceClient` (upload half) and the `LecturerRecipientsClient`.
class LecturerAppClient {
  const LecturerAppClient();

  Future<List<FromOverviewUnit>> overview(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson('/api/v1/lecturer/overview', token: token);
      if (o is! Map<String, dynamic>) return const [];
      final units = o['units'];
      if (units is! List) return const [];
      return units.whereType<Map<String, dynamic>>().map(FromOverviewUnit.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  Future<List<LectRosterRow>> roster(String token,
      {String scope = 'enrolled', String? unitId}) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson(
        '/api/v1/lecturer/roster?scope=${Uri.encodeQueryComponent(scope)}'
        '${unitId != null && unitId.isNotEmpty ? '&unit_id=${Uri.encodeQueryComponent(unitId)}' : ''}',
        token: token,
      );
      if (o is! List) return const [];
      return o.whereType<Map<String, dynamic>>().map(LectRosterRow.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  Future<List<LectSession>> sessions(String token, {String? unitId}) async {
    if (token.isEmpty) return const [];
    try {
      final o = await Net.getJson(
        '/api/v1/lecturer/sessions'
        '${unitId != null && unitId.isNotEmpty ? '?unit_id=${Uri.encodeQueryComponent(unitId)}' : ''}',
        token: token,
      );
      if (o is! List) return const [];
      return o.whereType<Map<String, dynamic>>().map(LectSession.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  Future<List<LectSessionStudent>> sessionStudents(
      String token, String sessionId) async {
    if (token.isEmpty || sessionId.isEmpty) return const [];
    try {
      final o = await Net.getJson(
          '/api/v1/lecturer/sessions/$sessionId/students?status=all',
          token: token);
      if (o is! Map<String, dynamic>) return const [];
      final students = o['students'];
      if (students is! List) return const [];
      return students
          .whereType<Map<String, dynamic>>()
          .map(LectSessionStudent.fromJson)
          .toList();
    } on Object {
      return const [];
    }
  }

  /// The slot grid of the week. Null on failure (offline), so the caller can fall
  /// back to its cached copy and say so.
  Future<List<LectSlot>?> timetable(String token) async {
    if (token.isEmpty) return null;
    try {
      final o = await Net.getJson('/api/v1/lecturer/timetable', token: token);
      if (o is! Map<String, dynamic>) return null;
      final slots = o['slots'];
      if (slots is! List) return null;
      return slots
          .whereType<Map<String, dynamic>>()
          .map(LectSlot.fromJson)
          .where((s) => s.startTime.isNotEmpty && s.dayOfWeek >= 1 && s.dayOfWeek <= 7)
          .toList();
    } on Object {
      return null;
    }
  }

  Future<LecturerCalendar?> calendar(String token, String from, String to,
      {String? unitId}) async {
    if (token.isEmpty) return null;
    try {
      final o = await Net.getJson(
        '/api/v1/lecturer/calendar?from=$from&to=$to'
        '${unitId != null && unitId.isNotEmpty ? '&unit_id=${Uri.encodeQueryComponent(unitId)}' : ''}',
        token: token,
      );
      if (o is! Map<String, dynamic>) return null;
      return LecturerCalendar.fromJson(o);
    } on Object {
      return null;
    }
  }

  /// Who the lecturer can write to, by name — coordinators and students.
  Future<(List<LecturerRecipient>, List<LecturerRecipient>)> recipients(
      String token) async {
    if (token.isEmpty) return (const <LecturerRecipient>[], const <LecturerRecipient>[]);
    try {
      final o = await Net.getJson('/api/v1/lecturer/recipients', token: token);
      if (o is! Map<String, dynamic>) {
        return (const <LecturerRecipient>[], const <LecturerRecipient>[]);
      }
      final coords = (o['coordinators'] ?? const []) as List;
      final studs = (o['students'] ?? const []) as List;
      return (
        coords
            .whereType<Map<String, dynamic>>()
            .map(
              (c) => LecturerRecipient(
                userId: (c['user_id'] ?? '') as String,
                name: (c['full_name'] ?? '') as String,
                cohort: (c['cohort'] ?? '') as String,
                course: (c['course_name'] ?? '') as String,
              ),
            )
            .toList(),
        studs
            .whereType<Map<String, dynamic>>()
            .map(
              (s) => LecturerRecipient(
                userId: (s['student_id'] ?? '') as String,
                name: (s['full_name'] ?? '') as String,
                cohort: (s['cohort'] ?? '') as String,
              ),
            )
            .toList(),
      );
    } on Object {
      return (const <LecturerRecipient>[], const <LecturerRecipient>[]);
    }
  }

  /// Upload queued presence claims, one by one (never batch): a partial failure can
  /// then say exactly which claim arrived. Returns the sent/failed counts.
  Future<(int, int)> uploadPresenceClaims(
      String token, List<PresenceClaim> claims) async {
    if (token.isEmpty || claims.isEmpty) return (0, 0);
    var sent = 0;
    var failed = 0;
    for (final c in claims) {
      try {
        await Net.postJson('/api/v1/lecturer/presence-claims',
            token: token, body: {'claims': [c.toJson()]});
        sent++;
      } on Object {
        failed++;
      }
    }
    return (sent, failed);
  }

  Future<OnlineClassLive?> onlineClassCurrent(String token) async {
    if (token.isEmpty) return null;
    try {
      final o = await Net.getJson('/api/v1/lecturer/online-class', token: token);
      if (o is! Map<String, dynamic>) return null;
      return OnlineClassLive.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<OnlineClassLive?> onlineClassStart(
      String token, String unitId, String offeringId, String fingerprint) async {
    if (token.isEmpty || unitId.isEmpty) return null;
    try {
      final o = await Net.postJson(
        '/api/v1/lecturer/online-class',
        token: token,
        body: {
          'unit_id': unitId,
          if (offeringId.isNotEmpty) 'offering_id': offeringId,
          'fingerprint': fingerprint,
        },
      );
      if (o is! Map<String, dynamic>) return null;
      return OnlineClassLive.fromJson(o);
    } on Object {
      return null;
    }
  }

  Future<bool> onlineClassEnd(String token) async {
    if (token.isEmpty) return false;
    try {
      await Net.postJson('/api/v1/lecturer/online-class/end',
          token: token, body: const {});
      return true;
    } on Object {
      return false;
    }
  }
}