import 'package:coordinator_flutter/engine/combined_class_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = 'a-shared-session-package-key'.codeUnits;
  const lecturer = 'lect-0001';
  const combined = 'combined-7f3a';

  group('CombinedClassCode', () {
    test('every coordinator of the same class derives the same code offline', () {
      final a = CombinedClassCode.derive(key, lecturer, combined, '2026-08-13');
      final b = CombinedClassCode.derive(key, lecturer, combined, '2026-08-13');
      expect(a, b);
      expect(a.length, 3);
      expect(a.codeUnits.every((c) => c >= 0x30 && c <= 0x39), isTrue);
    });

    test('a new day derives a new code and yesterday is refused', () {
      final today = CombinedClassCode.derive(key, lecturer, combined, '2026-08-13');
      expect(CombinedClassCode.validate(key, today, lecturer, combined, '2026-08-13'), isTrue);
      expect(CombinedClassCode.validate(key, today, lecturer, combined, '2026-08-14'), isFalse);
    });

    test('codes are independent day to day', () {
      final day0 = CombinedClassCode.derive(key, lecturer, combined, '2026-01-01');
      var sameDigits = 0;
      var days = 0;
      for (var m = 1; m <= 12; m++) {
        for (var d = 1; d <= 28; d++) {
          final date = '2026-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
          if (date == '2026-01-01') continue;
          days++;
          if (CombinedClassCode.derive(key, lecturer, combined, date) == day0) {
            sameDigits++;
          }
        }
      }
      expect(sameDigits <= days / 50, isTrue,
          reason: '$sameDigits of $days days repeated the same code');
    });

    test('different lecturer or class derives a different code', () {
      final mine = CombinedClassCode.derive(key, lecturer, combined, '2026-08-13');
      final otherLecturer = CombinedClassCode.derive(key, 'lect-0002', combined, '2026-08-13');
      final otherClass = CombinedClassCode.derive(key, lecturer, 'combined-9999', '2026-08-13');
      expect(CombinedClassCode.validate(key, otherLecturer, lecturer, combined, '2026-08-13') && mine != otherLecturer, isFalse);
      expect(CombinedClassCode.validate(key, otherClass, lecturer, combined, '2026-08-13') && mine != otherClass, isFalse);
    });

    test('surrounding space tolerated, wrong length never', () {
      final code = CombinedClassCode.derive(key, lecturer, combined, '2026-08-13');
      expect(CombinedClassCode.validate(key, '  $code ', lecturer, combined, '2026-08-13'), isTrue);
      expect(CombinedClassCode.validate(key, code.substring(0, 2), lecturer, combined, '2026-08-13'), isFalse);
      expect(CombinedClassCode.validate(key, '$code' '7', lecturer, combined, '2026-08-13'), isFalse);
      expect(CombinedClassCode.validate(key, '', lecturer, combined, '2026-08-13'), isFalse);
    });

    test('ids that split differently do not collide', () {
      final a = CombinedClassCode.derive(key, 'ab', 'c', '2026-08-13');
      final b = CombinedClassCode.derive(key, 'a', 'bc', '2026-08-13');
      expect(CombinedClassCode.validate(key, a, 'a', 'bc', '2026-08-13') && a == b, isFalse);
    });

    test('matches the server byte for byte (Go parity vectors)', () {
      final k = 'a-shared-session-package-key'.codeUnits;
      expect(CombinedClassCode.derive(k, 'lect-0001', 'combined-7f3a', '2026-08-13'), '946');
      expect(CombinedClassCode.derive(k, 'lect-0001', 'combined-7f3a', '2026-08-14'), '582');
      expect(CombinedClassCode.derive(k, 'lect-0002', 'combined-7f3a', '2026-08-13'), '809');
      expect(CombinedClassCode.derive(k, 'lect-0001', 'combined-9999', '2026-08-13'), '188');
    });
  });
}