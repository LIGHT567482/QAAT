import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:coordinator_flutter/net/auth_client.dart';
import 'package:coordinator_flutter/net/net.dart';

void main() {
  tearDown(() => Net.shared = http.Client());

  test('appLogin parses the full augmented response', () async {
    Net.shared = MockClient((req) async {
      expect(req.url.path, '/api/v1/auth/app-login');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['identifier'], 'coord@kiu.ac.ug');
      expect(body['password'], 'pw');
      expect(body.containsKey('totp_code'), isFalse);
      return http.Response(
        jsonEncode({
          'access_token': 'TOK',
          'role': 'COORDINATOR',
          'user_id': 'u1',
          'tenant_id': 't1',
          'full_name': 'Ada Coordinator',
          'title': 'Dr',
          'device_binding_key': 'BIND-1',
          'force_password_change': false,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final r = await const AuthClient().appLogin('coord@kiu.ac.ug', 'pw');
    expect(r, isNotNull);
    expect(r!.token, 'TOK');
    expect(r.role, 'COORDINATOR');
    expect(r.fullName, 'Ada Coordinator');
    expect(r.deviceBindingKey, 'BIND-1');
    expect(r.forcePasswordChange, isFalse);
    expect(r.displayName('coord@kiu.ac.ug'), 'Ada Coordinator');
  });

  test('appLogin sends totp_code once MFA is active', () async {
    Net.shared = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['totp_code'], '123456');
      return http.Response(
        jsonEncode({'access_token': 'TOK', 'role': 'STUDENT', 'user_id': 'u',
            'tenant_id': 't', 'student_id': 'ST-1'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final r = await const AuthClient().appLogin('ST-1', 'pw', totp: '123456');
    expect(r!.studentId, 'ST-1');
  });

  test('MFA_REQUIRED returns null so the caller prompts for a code', () async {
    Net.shared = MockClient((req) async {
      return http.Response(
        jsonEncode({'error': 'MFA_REQUIRED', 'message': 'TOTP code is required for this role'}),
        403,
        headers: {'content-type': 'application/json'},
      );
    });

    final r = await const AuthClient().appLogin('vc@kiu.ac.ug', 'pw');
    expect(r, isNull);
  });

  test('invalid credentials surfaces the server message', () async {
    Net.shared = MockClient((req) async {
      return http.Response(
        jsonEncode({'error': 'INVALID_CREDENTIALS', 'message': 'invalid email or password'}),
        401,
        headers: {'content-type': 'application/json'},
      );
    });

    await expectLater(
      const AuthClient().appLogin('x@kiu.ac.ug', 'nope'),
      throwsA(isA<NetFailure>()
          .having((f) => f.statusCode, 'statusCode', 401)
          .having((f) => f.code, 'code', 'INVALID_CREDENTIALS')
          .having((f) => f.message, 'message', 'invalid email or password')
          .having((f) => f.isMfaRequired, 'isMfaRequired', isFalse)),
    );
  });

  test('appLogin backs off through a 429', () async {
    var calls = 0;
    Net.shared = MockClient((req) async {
      calls++;
      if (calls == 1) {
        return http.Response('slow down', 429,
            headers: {'retry-after': '0', 'content-type': 'application/json'});
      }
      return http.Response(
        jsonEncode({'access_token': 'TOK', 'role': 'LECTURER', 'user_id': 'u',
            'tenant_id': 't', 'staff_id': 'S4'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final r = await const AuthClient().appLogin('lect@kiu.ac.ug', 'pw');
    expect(r!.staffId, 'S4');
    expect(calls, 2);
  });

  test('changePassword returns null on success, the message on refusal', () async {
    var call = 0;
    Net.shared = MockClient((req) async {
      call++;
      expect(req.url.path, '/api/v1/auth/change-password');
      expect(req.headers['Authorization'], 'Bearer TOK');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['current_password'], 'Default1234');
      expect(body['new_password'], 'MyOwn1234');
      if (call == 1) {
        return http.Response(
          jsonEncode({'error': 'INVALID_CREDENTIALS', 'message': 'current password is incorrect'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 200);
    });

    expect(await const AuthClient().changePassword('TOK', 'Default1234', 'MyOwn1234'),
        'current password is incorrect');
    expect(await const AuthClient().changePassword('TOK', 'Default1234', 'MyOwn1234'),
        isNull);
    expect(call, 2);
  });
}