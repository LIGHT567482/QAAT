import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coordinator_flutter/main.dart';

void main() {
  testWidgets('app boots to the login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const QaatCoordinatorApp());

    expect(find.text('KIU QAAT'), findsOneWidget);
    expect(find.text('Email / Reg. no / Staff ID'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);

    // Sign in is disabled until an identifier and password are typed.
    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'));
    expect(button.onPressed, isNull);
  });
}