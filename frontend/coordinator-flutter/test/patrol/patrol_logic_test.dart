import 'package:flutter_test/flutter_test.dart';

import 'package:coordinator_flutter/patrol/office_search_match.dart';
import 'package:coordinator_flutter/patrol/patrol_models.dart';
import 'package:coordinator_flutter/patrol/patrol_store.dart';
import 'package:coordinator_flutter/ui/patrol/manual_attendance_sheet.dart';
import 'package:coordinator_flutter/ui/patrol/office_round_tab.dart';
import 'package:coordinator_flutter/ui/patrol/patrol_alerts_tab.dart';
import 'package:coordinator_flutter/ui/patrol/patrol_round_tab.dart';

void main() {
  group('OfficeSearchMatch', () {
    const people = [
      OfficePerson(staffId: 'KIU/044', fullName: 'DR ANUMOLU SRINIVASA RAO',
          department: 'Computing', jobTitle: 'Lecturer', office: 'Block C, Room 14'),
      OfficePerson(staffId: 'KIU/128', fullName: 'NAKATO JOAN',
          department: 'Finance', jobTitle: 'Accountant', office: 'Block A, Room 2'),
    ];

    // An empty query matches nobody, deliberately — a round that opened on everybody
    // would invite recording without visiting.
    test('empty query matches nobody', () {
      expect(OfficeSearchMatch.filter(people, ''), isEmpty);
      expect(OfficeSearchMatch.filter(people, '   '), isEmpty);
    });

    test('staff id is a PREFIX match, case/space-insensitive', () {
      // "kiu/0" reaches KIU/044.
      expect(OfficeSearchMatch.filter(people, 'kiu/0'),
          [isA<OfficePerson>().having((p) => p.staffId, 'staffId', 'KIU/044')]);
      expect(OfficeSearchMatch.filter(people, 'KIU/128').length, 1);
      // A matching fragment ("044") does NOT contains-match the badge.
      expect(OfficeSearchMatch.filter(people, '044'), isEmpty);
    });

    test('name, department and office are CONTAINS matches', () {
      // Announced as "ANUMOLU" on the door — the registry has the full name.
      expect(OfficeSearchMatch.filter(people, 'anumolu').length, 1);
      expect(OfficeSearchMatch.filter(people, 'nakato').length, 1);
      expect(OfficeSearchMatch.filter(people, 'finance').length, 1);
      expect(OfficeSearchMatch.filter(people, 'block c').length, 1);
    });

    test('sorts by lowercased full name', () {
      final hits = OfficeSearchMatch.filter(people, 'kiu/');
      expect(hits.map((p) => p.fullName).toList(),
          ['DR ANUMOLU SRINIVASA RAO', 'NAKATO JOAN']);
    });
  });

  group('officeVerdictLabel', () {
    test('the three verdicts, and unknown passthrough', () {
      expect(officeVerdictLabel('AT_OFFICE'), 'At their office');
      expect(officeVerdictLabel('ELSEWHERE_ON_DUTY'), 'Elsewhere, on duty');
      // "Office empty" — never "Absent": one knock establishes an empty door, not an
      // absence, and only "Office empty" is reported to the person.
      expect(officeVerdictLabel('ABSENT'), 'Office empty');
      expect(officeVerdictLabel('SOMETHING_ELSE'), 'SOMETHING_ELSE');
    });
  });

  group('manual-sheet time/date shaping', () {
    test('isHHMM', () {
      expect(isHHMM('08:30'), isTrue);
      expect(isHHMM('23:59'), isTrue);
      expect(isHHMM('24:00'), isFalse);
      expect(isHHMM('8:30'), isFalse);
      expect(isHHMM('0830'), isFalse);
    });

    test('endsAfterHHMM refuses a backwards span', () {
      expect(endsAfterHHMM('10:00', '11:00'), isTrue);
      expect(endsAfterHHMM('11:00', '10:00'), isFalse);
      expect(endsAfterHHMM('10:00', '10:00'), isFalse);
      expect(endsAfterHHMM('', '10:00'), isFalse);
    });
  });

  group('formatSentAt', () {
    test('malformed input passes through untouched', () {
      expect(formatSentAt('not-a-date'), 'not-a-date');
    });

    test('a recent alert reads relative, with the exact time alongside', () {
      final now = DateTime.now().toUtc().toIso8601String();
      final s = formatSentAt(now);
      expect(s, contains('just now'));
      expect(s, contains(' · '));
    });

    test('an old alert reads as the exact date only', () {
      final s = formatSentAt('2020-01-05T09:30:00Z');
      expect(s, isNot(contains('ago')));
      expect(s, contains('2020'));
    });
  });

  group('PatrolSlot identity', () {
    test('key includes offering so two intakes never collide', () {
      // Same unit, same hour, two cohorts.
      expect(PatrolSlot.key('CS201', '10:00', 'cohort-day'),
          isNot(PatrolSlot.key('CS201', '10:00', 'cohort-weekend')));
      expect(PatrolSlot.key('CS201', '10:00', 'cohort-day'),
          PatrolSlot.key('CS201', '10:00', 'cohort-day'));
    });
  });

  group('todayDate', () {
    test('is YYYY-MM-DD with zero padding', () {
      final now = DateTime.now();
      final expected = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      expect(todayDate(), expected);
    });
  });

  group('InMemoryPatrolStore', () {
    test('queues a log, marks it synced, clears on sign-out', () async {
      final store = InMemoryPatrolStore();
      const log = PatrolLog(
          id: 'a', unitId: 'CS201', lecturerId: 'KIU/044', taught: true,
          sessionDate: '2026-09-08', scheduledTime: '10:00', takenAt: '2026-09-08T10:05:00Z');

      await store.putPatrolLog(log);
      expect(await store.pendingPatrolCount(), 1);
      expect((await store.patrolLogsForDay('2026-09-08')).length, 1);

      await store.markPatrolLogSynced('a');
      expect(await store.pendingPatrolCount(), 0);

      await store.clearAllForSignOut();
      expect(await store.patrolLogsForDay('2026-09-08'), isEmpty);
    });

    test('office visits keyed by visit_id idempotently', () async {
      final store = InMemoryPatrolStore();
      const v = OfficeVisit(
          id: 'v1', staffId: 'KIU/044', status: 'ABSENT',
          visitDate: '2026-09-08', visitTime: '09:00', capturedAt: '2026-09-08T09:00:00Z');
      await store.putOfficeVisit(v);
      await store.putOfficeVisit(v); // a retried batch updates in place
      expect((await store.officeVisitsForDay('2026-09-08')).length, 1);
      await store.markOfficeVisitSynced('v1');
      expect(await store.pendingOfficeCount(), 0);
    });
  });
}