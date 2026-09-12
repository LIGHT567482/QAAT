import 'package:coordinator_flutter/engine/attendance_trends.dart';
import 'package:coordinator_flutter/engine/chronic_absentee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChronicAbsentee', () {
    final sessions = ['s1', 's2', 's3', 's4', 's5'];
    final attended = {
      'A': {'s1', 's2'},
      'B': <String>{},
      'C': {'s1', 's2', 's3', 's4', 's5'},
      'D': {'s1', 's2', 's3', 's4'},
    };

    test('flags 2, CRITICAL first = B', () {
      final flagged = ChronicAbsentee().evaluate(sessions, attended, ['A', 'B', 'C', 'D']);
      expect(flagged.length, 2);
      expect(flagged.first.studentId, 'B');
      expect(flagged.first.status, AbsenteeStatus.critical);
      expect(flagged.first.consecutiveMissed, 5);
      expect(flagged.first.attendancePct, 0.0);
      expect(flagged.first.lastAttendedSession, isNull);
      final a = flagged.firstWhere((f) => f.studentId == 'A');
      expect(a.status, AbsenteeStatus.warning);
      expect(a.consecutiveMissed, 3);
      expect(a.lastAttendedSession, 's2');
      expect(flagged.any((f) => f.studentId == 'C' || f.studentId == 'D'), isFalse);
    });
  });

  group('AttendanceTrends', () {
    test('matches reference outcome', () {
      final t = AttendanceTrends().compute(const [
        WeekInput('W1', 45, 60),
        WeekInput('W2', 30, 60),
        WeekInput('W3', 54, 60),
      ]);
      expect(t.currentWeekRate, 90.0);
      expect((t.semesterAverage - 71.6667).abs(), lessThan(0.01));
      expect(t.bestWeek!.label, 'W3');
      expect(t.worstWeek!.label, 'W2');
      expect(t.weeksBelowThreshold, 1);
      expect(t.trend, Trend.rising);
      expect(t.totalSessions, 3);
      expect(t.weeks.length, 3);
    });

    test('empty input yields stable zero summary', () {
      final t = AttendanceTrends().compute(const []);
      expect(t.trend, Trend.stable);
      expect(t.currentWeekRate, 0.0);
      expect(t.totalSessions, 0);
      expect(t.bestWeek, isNull);
    });
  });
}