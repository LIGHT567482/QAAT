import 'package:coordinator_flutter/engine/room_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final secret = 'a-32-byte-test-secret-for-totp!!'.codeUnits;
  final gateSecret = 'gate-secret'.codeUnits;

  group('RoomCode', () {
    test('derive is deterministic, six digits', () {
      const t = 1700000000;
      final a = RoomCode.derive(secret, t);
      final b = RoomCode.derive(secret, t);
      expect(a, b);
      expect(a.length, 6);
      expect(a.codeUnits.every((c) => c >= 0x30 && c <= 0x39), isTrue);
    });

    test('code rotates across steps', () {
      const base = 1700000000 - (1700000000 % 10);
      expect(RoomCode.derive(secret, base), isNot(RoomCode.derive(secret, base + 10)));
    });

    test('matches the Go server derive vectors', () {
      expect(RoomCode.derive(secret, 1700000000), '218785');
      expect(RoomCode.derive(secret, 1700000123), '208813');
      expect(RoomCode.staticCode(secret), '378580');
      expect(RoomCode.derive(gateSecret, 1782604800), '082494');
      expect(RoomCode.staticCode(gateSecret), '203243');
    });

    test('validate accepts current and ±1 skew', () {
      const t = 1700000123;
      final code = RoomCode.derive(secret, t);
      expect(RoomCode.validate(secret, code, t), isTrue);
      expect(RoomCode.validate(secret, code, t + 10), isTrue);
      expect(RoomCode.validate(secret, code, t - 10), isTrue);
      expect(RoomCode.validate(secret, code, t + 20), isFalse);
    });

    test('rejects wrong secret and shape', () {
      const t = 1700000123;
      final code = RoomCode.derive(secret, t);
      final other = 'a-different-32-byte-secret-value!'.codeUnits;
      expect(RoomCode.validate(other, code, t), isFalse);
      expect(RoomCode.validate(secret, '12345', t), isFalse);
      expect(RoomCode.validate(secret, '1234567', t), isFalse);
      expect(RoomCode.validate(secret, '', t), isFalse);
    });

    test('secondsRemaining at boundary', () {
      const base = 1700000000 - (1700000000 % 10);
      expect(RoomCode.secondsRemaining(base), 10);
      expect(RoomCode.secondsRemaining(base + 1), 9);
    });

    test('static code is deterministic and validateStatic', () {
      final sc = RoomCode.staticCode(secret);
      final otherSecret = 'a-different-32-byte-secret-value!'.codeUnits;
      final other = RoomCode.staticCode(otherSecret);
      expect(sc.length, 6);
      expect(RoomCode.validateStatic(secret, sc), isTrue);
      expect(RoomCode.validateStatic(otherSecret, other), isTrue);
      expect(RoomCode.validateStatic(secret, other), isFalse);
      expect(RoomCode.validateStatic(secret, '12345'), isFalse);
    });
  });
}