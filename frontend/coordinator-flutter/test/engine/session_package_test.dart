import 'dart:convert';

import 'package:coordinator_flutter/engine/models.dart';
import 'package:coordinator_flutter/engine/session_package.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionPackage', () {
    test('builds the exact body the sync-receiver reads', () {
      const record = AttendanceRecord(
        logId: 'log-1',
        sessionId: 'sess-1',
        studentIdHash: 'h-anne',
        deviceFingerprintHash: 'fp-x',
        sequenceNumber: 1,
        checkinTimestamp: '2026-08-13T09:00:00Z',
      );
      final json = SessionPackage.build(
        sessionId: 'sess-1',
        coordinatorId: 'coord-1',
        records: const [record],
        sealedAt: '2026-08-13T09:05:00Z',
        unitId: 'unit-1',
        sessionDate: '2026-08-13',
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final session = decoded['session'] as Map<String, dynamic>;
      expect(session['session_id'], 'sess-1');
      expect(session['unit_id'], 'unit-1');
      expect(session['session_date'], '2026-08-13');
      expect(session['session_status'], 'CLOSED');
      final recs = decoded['attendance_records'] as List<dynamic>;
      expect(recs.length, 1);
      expect((recs[0] as Map<String, dynamic>)['sequence_number'], 1);
      expect(decoded['coordinator_id'], 'coord-1');
      expect(decoded['package_version'], '1.0');
      expect(decoded['sealed_at'], '2026-08-13T09:05:00Z');
    });

    test('emits no dangling comma when lecturer is absent', () {
      final json = SessionPackage.build(
        sessionId: 's1',
        coordinatorId: 'c1',
        records: const [],
        sealedAt: 't',
      );
      expect(json.contains('"},"lecturer"'), isFalse);
      expect(json.contains(',,"'), isFalse);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded.containsKey('lecturer'), isFalse);
    });

    test('includes lecturer scan with end fields', () {
      final json = SessionPackage.build(
        sessionId: 's1',
        coordinatorId: 'c1',
        records: const [],
        sealedAt: 't',
        lecturer: const LecturerScan(
          'KIU/STAFF/001',
          '2026-08-13T09:00:00Z',
          'fp-l',
          endedAt: '2026-08-13T10:00:00Z',
          endFingerprintHash: 'fp-end',
        ),
        sessionStatus: 'AUTO_CLOSED',
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final lecturer = decoded['lecturer'] as Map<String, dynamic>;
      expect(lecturer['lecturer_id'], 'KIU/STAFF/001');
      expect(lecturer['ended_at'], '2026-08-13T10:00:00Z');
      expect(lecturer['end_fingerprint_hash'], 'fp-end');
      expect((decoded['session'] as Map<String, dynamic>)['session_status'], 'AUTO_CLOSED');
    });
  });
}