import 'package:coordinator_flutter/crypto/qr_verify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QrVerify.canonicalBody', () {
    test('emits the 8 fields in canonical order', () {
      const p = QrPayload(
        'S1',
        'T1',
        'C1',
        'Name',
        '2026/2027',
        'SER-1',
        '2027-12-31',
        '2026-06-01T00:00:00Z',
      );
      expect(
        QrVerify.canonicalBody(p),
        '{"student_id":"S1","tenant_id":"T1","course_id":"C1","full_name":"Name",'
        '"academic_year":"2026/2027","serial_number":"SER-1",'
        '"expiry_date":"2027-12-31","issued_at":"2026-06-01T00:00:00Z"}',
      );
    });

    test('escapes quotes, backslashes and control chars', () {
      expect(
        QrVerify.canonicalBody(const QrPayload('a"b\\c', 'T\n', 'x', 'y', 'z', 's', 'd', 'i')),
        '{"student_id":"a\\"b\\\\c","tenant_id":"T\\n","course_id":"x","full_name":"y",'
        '"academic_year":"z","serial_number":"s","expiry_date":"d","issued_at":"i"}',
      );
    });
  });
}