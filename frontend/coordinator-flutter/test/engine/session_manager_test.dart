import 'package:coordinator_flutter/engine/session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionManager', () {
    test('IDLE → PENDING_LECTURER → ACTIVE → CLOSED', () {
      var now = 1000000;
      final sm = SessionManager('s1', nowMillis: () => now);
      expect(sm.state, SessionState.idle);
      sm.open();
      expect(sm.state, SessionState.pendingLecturer);
      expect(sm.startedAtMs, 1000000);
      sm.lecturerStarted();
      expect(sm.state, SessionState.active);
      expect(sm.gateOpenAtMs, 1000000);
      sm.close();
      expect(sm.state, SessionState.closed);
      expect(sm.closedAtMs, 1000000);
    });

    test('check-in window is T+120m from gate open', () {
      var now = 1000000;
      final sm = SessionManager('s1', nowMillis: () => now);
      sm.open();
      sm.lecturerStarted();
      now = 1000000 + SessionManager.checkinWindowMin * 60000 - 1;
      expect(sm.checkinOpen(), isTrue);
      now = 1000000 + SessionManager.checkinWindowMin * 60000;
      expect(sm.checkinOpen(), isFalse);
    });

    test('check-in closed until lecturer starts', () {
      final sm = SessionManager('s1', nowMillis: () => 1000000);
      sm.open();
      expect(sm.checkinOpen(), isFalse);
    });

    test('auto-expiry force-closes at T+180m from start', () {
      var now = 1000000;
      final sm = SessionManager('s1', nowMillis: () => now);
      sm.open();
      sm.lecturerStarted();
      now = 1000000 + SessionManager.forceCloseMin * 60000 - 1;
      expect(sm.tickAutoExpiry(), isFalse);
      expect(sm.state, isNot(SessionState.closed));
      now = 1000000 + SessionManager.forceCloseMin * 60000;
      expect(sm.tickAutoExpiry(), isTrue);
      expect(sm.state, SessionState.closed);
      expect(sm.tickAutoExpiry(), isFalse);
    });

    test('open twice throws', () {
      final sm = SessionManager('s1', nowMillis: () => 1000000);
      sm.open();
      expect(() => sm.open(), throwsStateError);
    });
  });
}