import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coordinator_flutter/net/auth_client.dart';
import 'package:coordinator_flutter/net/net.dart';
import 'package:coordinator_flutter/ui/home_screen.dart';
import 'package:coordinator_flutter/ui/login_screen.dart';

class _FakeAuth extends AuthClient {
  _FakeAuth({this.mfaFirst = false, this.failWith, this.delay});

  final bool mfaFirst;
  final Object? failWith;
  final Duration? delay;
  int calls = 0;

  @override
  Future<LoginResult?> appLogin(
    String identifier,
    String password, {
    String? totp,
  }) async {
    calls++;
    final wait = delay;
    if (wait != null) await Future<void>.delayed(wait);
    final err = failWith;
    if (err != null) throw err;
    if (mfaFirst && totp == null) return null;
    return const LoginResult(
      token: 'TOK',
      role: 'COORDINATOR',
      userId: 'u1',
      tenantId: 't1',
      fullName: 'Ada Coordinator',
    );
  }
}

Widget _app(_FakeAuth auth) => MaterialApp(
      initialRoute: '/login',
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/login':
            return MaterialPageRoute<void>(
              builder: (_) => LoginScreen(auth: auth),
              settings: settings,
            );
          case '/home':
            return MaterialPageRoute<void>(
              builder: (_) =>
                  HomeScreen(result: settings.arguments! as LoginResult),
              settings: settings,
            );
          default:
            return MaterialPageRoute<void>(builder: (_) => const SizedBox());
        }
      },
    );

void main() {
  // The login screen persists the signed-in session (offline-tolerant boot); give
  // the storage plugin an in-memory store so destructuring works under test.
  SharedPreferences.setMockInitialValues({});

  testWidgets('sign-in button stays disabled until both fields are filled',
      (tester) async {
    final auth = _FakeAuth();
    await tester.pumpWidget(_app(auth));

    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'));
    expect(button.onPressed, isNull);

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'coord');
    await tester.pump();
    // Identifier alone is still not enough.
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
            .onPressed,
        isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
            .onPressed,
        isNotNull);
  });

  testWidgets('successful login lands on the coordinator hub', (tester) async {
    final auth = _FakeAuth();
    await tester.pumpWidget(_app(auth));

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'coord');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(auth.calls, 1);
    expect(find.textContaining('Welcome, Ada Coordinator'), findsOneWidget);
    expect(find.text('Attendance'), findsOneWidget);
  });

  testWidgets('server refusal shows its words without navigating',
      (tester) async {
    final auth = _FakeAuth(
        failWith: NetFailure(401, 'INVALID_CREDENTIALS', 'invalid email or password'));
    await tester.pumpWidget(_app(auth));

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'coord');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'nope');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('invalid email or password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('secure-connection error shows the clock-fix hint', (tester) async {
    final auth = _FakeAuth(
        failWith: Exception('Secure connection failed. Handshake error: tls'));
    await tester.pumpWidget(_app(auth));

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'coord');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Set time automatically'), findsOneWidget);
  });

  testWidgets('MFA_REQUIRED reveals the code field, then submits with the code',
      (tester) async {
    final auth = _FakeAuth(mfaFirst: true);
    await tester.pumpWidget(_app(auth));

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'vc');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // First submit answered MFA_REQUIRED — stay on the screen, ask for the code.
    expect(find.text('Authenticator code'), findsOneWidget);
    expect(find.textContaining('Welcome, Ada'), findsNothing);
    expect(auth.calls, 1);

    // But Sign in should still be allowed to retry (keep the typed credentials).
    await tester.enterText(
        find.widgetWithText(TextField, 'Authenticator code'), '123456');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(auth.calls, 2);
    expect(find.textContaining('Welcome, Ada'), findsOneWidget);
  });

  testWidgets('busy state disables the button while signing in', (tester) async {
    final auth = _FakeAuth(delay: const Duration(milliseconds: 300));
    await tester.pumpWidget(_app(auth));

    await tester.enterText(
        find.widgetWithText(TextField, 'Email / Reg. no / Staff ID'), 'coord');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');

    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump();

    // In-flight: busy label, disabled button, progress bar — no nav yet.
    expect(find.text('Signing in…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Signing in…'))
            .onPressed,
        isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('Welcome, Ada'), findsNothing);

    await tester.pumpAndSettle();
    expect(find.textContaining('Welcome, Ada'), findsOneWidget);
  });
}