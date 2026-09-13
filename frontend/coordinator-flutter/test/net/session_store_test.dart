import 'package:coordinator_flutter/net/auth_client.dart';
import 'package:coordinator_flutter/net/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved session round-trips through the server field names', () async {
    await SessionStore.save(const LoginResult(
      token: 'tok-1',
      role: 'QA_MONITOR',
      userId: 'u1',
      tenantId: 't1',
      fullName: 'Jane Monitor',
      staffId: 'KIU/310',
      deviceBindingKey: 'aGV5',
    ));

    final loaded = await SessionStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.token, 'tok-1');
    expect(loaded.role, 'QA_MONITOR');
    expect(loaded.staffId, 'KIU/310');
    expect(loaded.deviceBindingKey, 'aGV5');
  });

  test('clear drops the session; no session loads as null', () async {
    await SessionStore.save(const LoginResult(
      token: 'tok-1',
      role: 'COORDINATOR',
      userId: 'u1',
      tenantId: 't1',
    ));
    expect(await SessionStore.load(), isNotNull);

    await SessionStore.clear();
    expect(await SessionStore.load(), isNull);
  });

  test('a corrupt saved session is dropped, never booted', () async {
    SharedPreferences.setMockInitialValues({
      'qaat.saved_session': 'not-json-at-all{{',
    });
    expect(await SessionStore.load(), isNull);
  });

  test('a token-less or role-less "session" is not a session', () async {
    SharedPreferences.setMockInitialValues({
      'qaat.saved_session': '{"access_token":"","role":"COORDINATOR"}',
    });
    expect(await SessionStore.load(), isNull);
  });
}