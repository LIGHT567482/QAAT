import 'package:coordinator_flutter/net/lecturer_attendance_client.dart';
import 'package:coordinator_flutter/ui/lecturer_attendance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Injectible double over [LecturerAttendanceClient]: canned data in, captured calls out.
class _FakeClient extends LecturerAttendanceClient {
  _FakeClient({
    this.summaryData = const [],
    this.logsData = const [],
    this.patrolData = const PatrolAttendance(summary: [], visits: []),
    this.referenceData = const PatrolReference(),
    this.manualResult,
  });

  final List<LecturerSummary> summaryData;
  final List<AttendanceLog> logsData;
  final PatrolAttendance patrolData;
  final PatrolReference referenceData;
  final String? manualResult;

  String? lastManualToken;
  ManualEntry? lastManual;
  final List<(String, String)> patrolQueries = [];

  @override
  Future<List<LecturerSummary>> summary(String token) async => summaryData;

  @override
  Future<List<AttendanceLog>> logs(String token) async => logsData;

  @override
  Future<PatrolAttendance> patrol(String token, {String from = '', String to = ''}) async {
    patrolQueries.add((from, to));
    return patrolData;
  }

  @override
  Future<PatrolReference> reference(String token) async {
    return referenceData;
  }

  @override
  Future<String?> manual(String token, ManualEntry e) async {
    lastManualToken = token;
    lastManual = e;
    return manualResult;
  }
}

void main() {
  const summaryRow = LecturerSummary(
    lecturerId: 'LE-1',
    lecturerName: 'Dr Alice',
    staffId: 'ST-1',
    department: 'Computer Science',
    email: 'alice@kiu.ac.ug',
    totalSessions: 2,
    totalContactHours: 3.0,
    avgContactHours: 1.5,
    lastSessionDate: '2026-08-13',
  );

  const logRow = AttendanceLog(
    logId: 'L-1',
    lecturerId: 'LE-1',
    lecturerName: 'Dr Alice',
    department: 'CS',
    unitId: 'BIT 3110',
    unitName: 'Software Design',
    sessionDate: '2026-08-13',
    gateOpenTime: '2026-08-13T08:00:00Z',
    gateCloseTime: '',
    contactHours: 1.5,
    sessionStatus: 'ACTIVE',
    studentsAttended: 42,
    classGroup: '2:1',
    qaMonitor: '',
    qaMonitorStaffId: '',
    isCompensation: false,
    compensationFor: '',
    room: 'LT-A',
    roomIsProvision: false,
    provisionNote: '',
    unscheduled: false,
    deliveryMode: 'IN_PERSON',
  );

  const patrolSummary = PatrolSummary(
    lecturerId: 'ST-1',
    lecturerName: 'Dr Alice',
    department: 'CS',
    school: 'Sciences',
    patrolled: 5,
    taught: 4,
    missed: 1,
    rate: 80.0,
    lastPatrolDate: '2026-08-14',
  );

  const patrolVisit = PatrolVisit(
    patrolId: 'P-1',
    lecturerId: 'ST-1',
    lecturerName: 'Dr Alice',
    unitId: 'BIT 3110',
    unitName: 'Software Design',
    room: 'LT-A',
    sessionDate: '2026-08-13',
    scheduledTime: '08:00',
    taught: true,
    patrollerName: '',
    patrollerStaffId: '',
    qaMonitor: 'J. Monitor',
    qaMonitorStaffId: 'MON-9',
    takenAt: '2026-08-13T08:05:00Z',
    classGroup: '2:1',
    studentsAttended: 42,
    isCompensation: false,
    compensationFor: '',
    entryMethod: 'PATROL',
    school: 'Sciences',
  );

  Widget app(_FakeClient client) => MaterialApp(
        home: LecturerAttendanceScreen(token: 'tok', client: client),
      );

  testWidgets('shows coordinator record tab and expands session logs', (tester) async {
    final client = _FakeClient(summaryData: const [summaryRow], logsData: const [logRow]);
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    expect(find.text('Lecturer Attendance'), findsOneWidget);
    expect(find.text('Dr Alice'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // total_sessions

    // Expand the lecturer row → the session log appears.
    await tester.tap(find.text('Dr Alice'));
    await tester.pumpAndSettle();
    expect(find.text('Software Design'), findsOneWidget);
    expect(find.text('BIT 3110'), findsOneWidget);
    expect(find.text('LT-A'), findsOneWidget);
  });

  testWidgets('QA monitor tab shows the monitor summary and visits', (tester) async {
    final client = _FakeClient(
      patrolData: const PatrolAttendance(summary: [patrolSummary], visits: [patrolVisit]),
    );
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('QA monitor record'));
    await tester.pumpAndSettle();

    expect(find.textContaining('found the lecturer teaching'), findsOneWidget);
    expect(find.text('ST-1'), findsOneWidget);

    // Expand → the visit row with the monitor's name and the TEACHING chip.
    await tester.tap(find.text('Dr Alice'));
    await tester.pumpAndSettle();
    expect(find.text('J. Monitor'), findsOneWidget);
    expect(find.text('TEACHING'), findsOneWidget);
  });

  testWidgets('manual sheet files a taught record through the client', (tester) async {
    final client = _FakeClient(
      referenceData: const PatrolReference(
        rooms: [RefItem('V-1', 'LT-A')],
        units: [RefItem('BIT 3110', 'Software Design')],
        lecturers: [RefItem('ST-1', 'Dr Alice', 'Computer Science')],
        schools: ['Sciences'],
        departments: [RefItem('CS', 'CS', 'Sciences')],
        lecturerSchools: {'ST-1': 'Sciences'},
        unitDefaults: {'BIT 3110': ('2:1', 'Sciences')},
        unitDepartments: {'BIT 3110': 'CS'},
      ),
    );
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record a lecture at the door'));
    await tester.pumpAndSettle();
    expect(find.text('Attendance recorded manually'), findsOneWidget);

    // Type the unit (accepting a typed value) into the pick-or-type field.
    await tester.enterText(
        find.widgetWithText(TextField, 'Course unit'), 'TYPED-UNIT');
    await tester.pumpAndSettle();

    // Same for the lecturer.
    await tester.enterText(find.widgetWithText(TextField, 'Lecturer'), 'Dr New');
    await tester.pumpAndSettle();

    // Scroll the verdict buttons into view and record as teaching.
    await tester.scrollUntilVisible(find.text('✓  Teaching'), 300,
        scrollable: find
            .descendant(
                of: find.byType(ManualAttendanceSheet),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('✓  Teaching'));
    await tester.pumpAndSettle();

    expect(client.lastManual, isNotNull);
    expect(client.lastManual!.unitName, 'TYPED-UNIT');
    expect(client.lastManual!.lecturerName, 'Dr New');
    expect(client.lastManual!.taught, isTrue);
    expect(client.lastManualToken, 'tok');
    // The sheet closed and the snackbar confirms.
    expect(find.text('Recorded — TYPED-UNIT'), findsOneWidget);
  });

  testWidgets('manual refusal keeps the sheet open and shows the server message',
      (tester) async {
    final client = _FakeClient(
      referenceData: const PatrolReference(
        rooms: [RefItem('V-1', 'LT-A')],
        units: [RefItem('BIT 3110', 'Software Design')],
      ),
      manualResult: 'choose a course unit or type its name',
    );
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record a lecture at the door'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Course unit'), 'TYPED-UNIT');
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('✗  Not teaching'), 300,
        scrollable: find
            .descendant(
                of: find.byType(ManualAttendanceSheet),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('✗  Not teaching'));
    await tester.pumpAndSettle();

    expect(client.lastManual!.taught, isFalse);
    // The sheet is still here and the server's words are on it — WHICH field is wrong.
    expect(find.text('Attendance recorded manually'), findsOneWidget);
    expect(find.text('choose a course unit or type its name'), findsOneWidget);
    expect(find.text('Recorded — TYPED-UNIT'), findsNothing);
  });
}