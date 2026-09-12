import 'dart:convert';

import 'package:coordinator_flutter/net/lecturer_attendance_client.dart';
import 'package:coordinator_flutter/net/net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    Net.shared = MockClient((req) async => http.Response('{}', 404));
    Net.setBaseUrl('https://test.qaat.local');
  });

  test('summary parses per-lecturer aggregates', () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/dashboard/lecturer-attendance/summary');
      expect(req.headers['Authorization'], 'Bearer tok');
      return http.Response(
        jsonEncode([
          {
            'lecturer_id': 'LE-1',
            'lecturer_name': 'Dr A',
            'staff_id': 'ST-1',
            'department': 'Computer Science',
            'email': 'a@kiu.ac.ug',
            'total_sessions': 4,
            'total_contact_hours': 7.25,
            'avg_contact_hours': 1.8125,
            'last_session_date': '2026-08-13',
          }
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final s = await LecturerAttendanceClient().summary('tok');
    expect(s, hasLength(1));
    expect(s.first.lecturerId, 'LE-1');
    expect(s.first.staffId, 'ST-1');
    expect(s.first.totalSessions, 4);
    expect(s.first.totalContactHours, 7.25);
    expect(s.first.lastSessionDate, '2026-08-13');
  });

  test('logs parse session-log rows including the derived extras', () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/dashboard/lecturer-attendance');
      return http.Response(
        jsonEncode([
          {
            'log_id': 'L-1',
            'lecturer_id': 'LE-1',
            'lecturer_name': 'Dr A',
            'department': 'CS',
            'unit_id': 'BIT 3110',
            'unit_name': 'Software Design',
            'session_date': '2026-08-13',
            'gate_open_time': '2026-08-13T08:00:00Z',
            'gate_close_time': '2026-08-13T09:30:00Z',
            'contact_hours': 1.5,
            'session_status': 'COMPLETED',
            'students_attended': 42,
            'class_group': '2:1',
            'qa_monitor': 'J. Monitor',
            'qa_monitor_staff_id': 'MON-9',
            'is_compensation': true,
            'compensation_for': '2026-08-06',
            'room': 'LT-A',
            'room_is_provision': true,
            'provision_note': 'LT-A substituted at the door',
            'unscheduled': false,
            'delivery_mode': 'IN_PERSON',
          }
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final logs = await LecturerAttendanceClient().logs('tok');
    expect(logs, hasLength(1));
    final l = logs.first;
    expect(l.contactHours, 1.5);
    expect(l.classGroup, '2:1');
    expect(l.qaMonitor, 'J. Monitor');
    expect(l.isCompensation, isTrue);
    expect(l.roomIsProvision, isTrue);
    expect(l.compensationFor, '2026-08-06');
    expect(l.deliveryMode, 'IN_PERSON');
  });

  test('patrol appends from/to date filters and parses the two lists', () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/dashboard/lecturer-attendance/patrol');
      expect(req.url.queryParameters['from'], '2026-08-01');
      expect(req.url.queryParameters['to'], '2026-08-31');
      return http.Response(
        jsonEncode({
          'summary': [
            {
              'lecturer_id': 'ST-1',
              'lecturer_name': 'Dr A',
              'department': 'CS',
              'school': 'Sciences',
              'patrolled': 5,
              'taught': 4,
              'missed': 1,
              'rate': 80.0,
              'last_patrol_date': '2026-08-14',
            }
          ],
          'visits': [
            {
              'patrol_id': 'P-1',
              'lecturer_id': 'ST-1',
              'lecturer_name': 'Dr A',
              'unit_id': 'BIT 3110',
              'unit_name': 'Software Design',
              'room': 'LT-A',
              'session_date': '2026-08-13',
              'scheduled_time': '08:00',
              'taught': true,
              'patroller_name': 'J. Monitor',
              'patroller_staff_id': 'MON-9',
              'qa_monitor': 'J. Monitor',
              'qa_monitor_staff_id': 'MON-9',
              'taken_at': '2026-08-13T08:05:00Z',
              'class_group': '2:1',
              'students_attended': 42,
              'is_compensation': false,
              'compensation_for': '',
              'entry_method': 'PATROL',
              'school': 'Sciences',
            }
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final p = await LecturerAttendanceClient().patrol('tok',
        from: '2026-08-01', to: '2026-08-31');
    expect(p.summary, hasLength(1));
    expect(p.summary.first.missed, 1);
    expect(p.summary.first.rate, closeTo(80.0, 0.001));
    expect(p.visits, hasLength(1));
    expect(p.visits.first.taught, isTrue);
    expect(p.visits.first.entryMethod, 'PATROL');
  });

  test('reference builds pick-lists and the lookup maps', () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/patrol/reference');
      expect(req.headers['X-Device-Fingerprint'], 'fp-123');
      return http.Response(
        jsonEncode({
          'rooms': [
            {'venue_id': 'V-1', 'name': 'LT-A', 'building': 'Main'},
          ],
          'units': [
            {
              'unit_id': 'BIT 3110',
              'unit_name': 'Software Design',
              'course_id': 'CSI',
              'department': 'CS',
              'school': 'Sciences',
              'class_group': '2:1',
            },
          ],
          'lecturers': [
            {
              'staff_id': 'ST-1',
              'full_name': 'Dr A',
              'department': 'CS',
              'school': 'Sciences',
            },
          ],
          'schools': ['Sciences'],
          'departments': [
            {'name': 'CS', 'school': 'Sciences'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final ref = await LecturerAttendanceClient(fingerprint: 'fp-123').reference('tok');
    expect(ref.rooms.single.label, 'LT-A');
    expect(ref.units.single.id, 'BIT 3110');
    expect(ref.lecturers.single.extra, 'CS');
    expect(ref.schools, ['Sciences']);
    expect(ref.departments.single.extra, 'Sciences');
    expect(ref.lecturerSchools['ST-1'], 'Sciences');
    expect(ref.unitDefaults['BIT 3110'], ('2:1', 'Sciences'));
    expect(ref.unitDepartments['BIT 3110'], 'CS');
  });

  test('manual returns null on success and the server message on refusal', () async {
    var call = 0;
    Net.shared = MockClient((req) async {
      call++;
      expect(req.url.path, '/api/v1/patrol/manual');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['unit_id'], 'BIT 3110');
      if (body['unit_name'] == 'refuse') {
        expect(body['taught'], true);
        return http.Response(
          jsonEncode({
            'error': 'INVALID_REQUEST',
            'message': 'choose a course unit or type its name',
          }),
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      expect(body['lecturer_name'], 'Dr A');
      expect(body['taught'], false);
      expect(body['session_date'], '2026-08-14');
      return http.Response(jsonEncode({'patrol_id': 'P-9', 'status': 'RECORDED'}), 200,
          headers: {'content-type': 'application/json'});
    });

    final c = LecturerAttendanceClient(fingerprint: 'fp-123');
    final ok = await c.manual('tok', ManualEntry(
          unitId: 'BIT 3110',
          lecturerName: 'Dr A',
          sessionDate: '2026-08-14',
          timeOfDay: '08:00',
          taught: false,
        ));
    expect(ok, isNull);
    expect(call, 1);

    final refused = await c.manual('tok', ManualEntry(
          unitId: 'BIT 3110',
          unitName: 'refuse',
          lecturerName: 'Dr A',
          taught: true,
        ));
    expect(refused, 'choose a course unit or type its name');
  });

  test('getJson backs off on 429 and retries (Retry-After honoured)', () async {
    var calls = 0;
    Net.shared = MockClient((req) async {
      calls++;
      if (calls == 1) {
        return http.Response('rate limited', 429, headers: {'retry-after': '0'});
      }
      return http.Response(jsonEncode(['ok']), 200,
          headers: {'content-type': 'application/json'});
    });

    final body = await Net.getJson('/api/v1/x', token: 'tok');
    expect(body, ['ok']);
    expect(calls, 2);
  });

  test('getJson surfaces a server message for a refused call', () async {
    Net.shared = MockClient((req) async {
      return http.Response(
        jsonEncode({'error': 'PIN_LOCKED', 'message': 'Wait 15 minutes'}),
        403,
        headers: {'content-type': 'application/json'},
      );
    });

    await expectLater(
      Net.getJson('/api/v1/x', token: 'tok'),
      throwsA(isA<NetFailure>()
          .having((f) => f.statusCode, 'statusCode', 403)
          .having((f) => f.code, 'code', 'PIN_LOCKED')
          .having((f) => f.message, 'message', 'Wait 15 minutes')),
    );
  });
}