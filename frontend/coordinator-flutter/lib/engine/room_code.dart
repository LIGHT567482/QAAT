import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

class RoomCode {
  static const int stepSeconds = 10;
  static const int digits = 6;
  static const int _skewSteps = 1;
  static const int _mod = 1000000;

  static String derive(List<int> secret, int epochSeconds) =>
      _deriveStep(secret, epochSeconds ~/ stepSeconds);

  static bool validate(List<int> secret, String code, int epochSeconds) {
    if (code.length != digits) return false;
    final current = epochSeconds ~/ stepSeconds;
    var ok = false;
    for (var d = -_skewSteps; d <= _skewSteps; d++) {
      if (_constantTimeEquals(_deriveStep(secret, current + d), code)) {
        ok = true;
      }
    }
    return ok;
  }

  static int secondsRemaining(int epochSeconds) =>
      stepSeconds - epochSeconds % stepSeconds;

  static String staticCode(List<int> secret) {
    final mac = crypto.Hmac(crypto.sha256, secret)
        .convert(utf8.encode('student-static-v1'))
        .bytes;
    final offset = mac[mac.length - 1] & 0x0f;
    final bin = ((mac[offset] & 0x7f) << 24) |
        ((mac[offset + 1] & 0xff) << 16) |
        ((mac[offset + 2] & 0xff) << 8) |
        (mac[offset + 3] & 0xff);
    final code = (bin & 0xffffffff) % _mod;
    return code.toString().padLeft(digits, '0');
  }

  static bool validateStatic(List<int> secret, String code) {
    if (code.trim().length != digits) return false;
    return _constantTimeEquals(staticCode(secret), code.trim());
  }

  static String _deriveStep(List<int> secret, int step) {
    final msg = Uint8List(8);
    var s = step;
    for (var i = 7; i >= 0; i--) {
      msg[i] = s & 0xff;
      s = s ~/ 256;
    }
    final mac = crypto.Hmac(crypto.sha256, secret).convert(msg).bytes;
    final offset = mac[mac.length - 1] & 0x0f;
    final bin = ((mac[offset] & 0x7f) << 24) |
        ((mac[offset + 1] & 0xff) << 16) |
        ((mac[offset + 2] & 0xff) << 8) |
        (mac[offset + 3] & 0xff);
    final code = (bin & 0xffffffff) % _mod;
    return code.toString().padLeft(digits, '0');
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r = r | (a.codeUnitAt(i) ^ b.codeUnitAt(i));
    }
    return r == 0;
  }
}