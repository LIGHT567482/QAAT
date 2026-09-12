import 'dart:convert';

import 'package:coordinator_flutter/net/net.dart';
import 'package:coordinator_flutter/net/portal_client.dart';
import 'package:coordinator_flutter/patrol/notification_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    Net.shared = MockClient((req) async => http.Response('{}', 404));
    Net.setBaseUrl('https://test.qaat.local');
  });

  test('composer send posts audience/subject/body and reads the recipient count',
      () async {
    late http.Request seen;
    Net.shared = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({'status': 'SENT', 'recipients': 3}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final out = await NotificationClient().send(
      'tok',
      audience: 'MONITORS',
      subject: 'Round 2 rooms changed',
      body: 'Rooms moved to block D.',
    );

    expect(out.error, isNull);
    expect(out.recipients, 3);
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/v1/app-notifications');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(jsonDecode(seen.body), {
      'audience': 'MONITORS',
      'subject': 'Round 2 rooms changed',
      'body': 'Rooms moved to block D.',
    });
  });

  test('one-coordinator send carries target_id', () async {
    late http.Request seen;
    Net.shared = MockClient((req) async {
      seen = req;
      return http.Response(
          jsonEncode({'status': 'SENT', 'recipients': 1}), 200);
    });

    final out = await NotificationClient().send(
      'tok',
      audience: 'COORDINATOR',
      targetId: 'coord-7',
      subject: 'Empty room',
      body: 'Room 12 was empty at 11:30.',
    );

    expect(out.recipients, 1);
    expect(jsonDecode(seen.body)['target_id'], 'coord-7');
  });

  test('a refusal is surfaced verbatim, not swallowed as a send', () async {
    Net.shared = MockClient((req) async => http.Response(
        jsonEncode({
          'error': 'NO_RECIPIENTS',
          'message':
              'nobody could be found to send this to (\u2026). Nothing was sent.',
        }),
        422,
        headers: {'content-type': 'application/json; charset=utf-8'}));

    final out = await NotificationClient().send(
      'tok',
      audience: 'LECTURERS',
      subject: 'Hi',
      body: 'Hello lecturers.',
    );

    expect(out.recipients, isNull);
    expect(out.error, contains('nobody could be found'));
  });

  test('the coordinator directory parses for the one-coordinator picker',
      () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/patrol/coordinators');
      return http.Response(
        jsonEncode([
          {'user_id': 'c1', 'full_name': 'Ada Coordinator', 'department': 'ICT'},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final cs = await const PortalClient().patrolCoordinators('tok');
    expect(cs, hasLength(1));
    expect(cs!.first.userId, 'c1');
    expect(cs.first.fullName, 'Ada Coordinator');
    expect(cs.first.department, 'ICT');
  });
}