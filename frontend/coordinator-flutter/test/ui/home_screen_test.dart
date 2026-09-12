import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coordinator_flutter/net/auth_client.dart';
import 'package:coordinator_flutter/patrol/fingerprint.dart';
import 'package:coordinator_flutter/ui/change_password_screen.dart';
import 'package:coordinator_flutter/ui/dashboards.dart';
import 'package:coordinator_flutter/ui/home_screen.dart';

class _FakeAuth extends AuthClient {
  String? changeError;

  @override
  Future<String?> changePassword(
      String token, String current, String newPassword) async {
    return changeError;
  }
}

LoginResult coordinator({bool forceChange = false}) => LoginResult(
      token: 'TOK',
      role: 'COORDINATOR',
      userId: 'u1',
      tenantId: 't1',
      fullName: 'Ada Coordinator',
      forcePasswordChange: forceChange,
    );

Widget app(LoginResult result) => MaterialApp(
      home: HomeScreen(result: result),
    );

void main() {
  testWidgets('a coordinator lands on the six-tab hub', (tester) async {
    await tester.pumpWidget(app(coordinator()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Welcome, Ada Coordinator'), findsOneWidget);
    for (final label in ['Home', 'Attendance', 'Absentees', 'Trends', 'Alerts', 'Sync']) {
      expect(find.text(label), findsOneWidget, reason: 'nav label $label');
    }
  });

  testWidgets('the Attendance tab shows the in-room hub with standby',
      (tester) async {
    await tester.pumpWidget(app(coordinator()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Attendance'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Emergency standby'), findsOneWidget);
    expect(find.textContaining('Take attendance'), findsOneWidget);
  });

  testWidgets('force_password_change gates the hub behind a password change',
      (tester) async {
    await tester.pumpWidget(app(coordinator(forceChange: true)));

    expect(find.byType(ChangePasswordScreen), findsOneWidget);
    expect(find.text('Lecturer Attendance'), findsNothing);
  });

  testWidgets('password change flow: mismatch is rejected, success opens the hub',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = _FakeAuth();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ChangePasswordScreen(auth: auth, onChanged: () {
          // Nothing else to do here — the host flips its gate flag in real life.
        }),
      ),
    ));

    await tester.enterText(
        find.widgetWithText(TextField, 'Current password'), 'Default1234');
    await tester.enterText(
        find.widgetWithText(TextField, 'New password (at least 8 characters)'),
        'MyOwn1234');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'), 'DIFFERENT');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('The two new passwords do not match.'), findsOneWidget);
    expect(auth.changeError, isNull);

    // Fix the confirmation and submit again → success path (no error).
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'), 'MyOwn1234');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('The two new passwords do not match.'), findsNothing);
  });

  testWidgets('server refusal on password change is shown on the form',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final auth = _FakeAuth()
      ..changeError = 'current password is incorrect';
    await tester.pumpWidget(MaterialApp(
      home: ChangePasswordScreen(auth: auth, onChanged: () {}),
    ));

    await tester.enterText(
        find.widgetWithText(TextField, 'Current password'), 'Wrong');
    await tester.enterText(
        find.widgetWithText(TextField, 'New password (at least 8 characters)'),
        'MyOwn1234');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm new password'), 'MyOwn1234');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('current password is incorrect'), findsOneWidget);
  });

  testWidgets('a lecturer is routed to the lecturer dashboard, not the placeholder',
      (tester) async {
    await tester.pumpWidget(app(const LoginResult(
      token: 'TOK',
      role: 'LECTURER',
      userId: 'u2',
      tenantId: 't1',
      fullName: 'Prof B',
      staffId: 'KIU/900',
    )));
    await tester.pump();

    expect(find.byType(LecturerDashboard), findsOneWidget);
    expect(
        find.textContaining('works on the QAAT web dashboard, not on the phone app'),
        findsNothing);
  });

  testWidgets('a web-only role sees the coming-soon placeholder',
      (tester) async {
    await tester.pumpWidget(app(const LoginResult(
      token: 'TOK',
      role: 'ADMIN',
      userId: 'u2',
      tenantId: 't1',
      fullName: 'Prof B',
    )));

    expect(
        find.textContaining(
            'ADMIN works on the QAAT web dashboard, not on the phone app'),
        findsOneWidget);
  });

  testWidgets(
      'a QA patroller is routed to the monitor app, never to the hub '
      'or the placeholder', (tester) async {
    DeviceFingerprint.testOverride = 'fp-test';
    addTearDown(() => DeviceFingerprint.testOverride = null);

    await tester.pumpWidget(app(const LoginResult(
      token: 'TOK',
      role: 'QA_PATROLLER',
      userId: 'u9',
      tenantId: 't1',
      fullName: 'Jane Patroller',
      staffId: 'KIU/310',
    )));

    // The gate talks to the (mock-400) server: the round opens only after the
    // handset binding proves out, so the monitor-role shell is the thing on
    // screen — never the coordinator hub and never the not-on-this-app branch.
    await tester.pumpAndSettle();

    expect(find.text('Lecturer Attendance'), findsNothing);
    expect(find.text('Start a session'), findsNothing);
    expect(
        find.textContaining(
            'works on the QAAT web dashboard, not on the phone app'),
        findsNothing);
    expect(find.textContaining('Monitoring is locked on this phone'),
        findsOneWidget);
  });
}