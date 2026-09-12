import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

class CombinedClassCode {
  static const int digits = 3;
  static const int _mod = 1000;

  static String derive(List<int> secret, String lecturerId, String classKey, String localDate) {
    final msg = ['combined-class-v1', lecturerId, classKey, localDate]
        .join('\u001F');
    final h = crypto.Hmac(crypto.sha256, secret).convert(utf8.encode(msg)).bytes;
    final off = h[h.length - 1] & 0x0f;
    final bin = ((h[off] & 0x7f) << 24) |
        ((h[off + 1] & 0xff) << 16) |
        ((h[off + 2] & 0xff) << 8) |
        (h[off + 3] & 0xff);
    final code = bin % _mod;
    return code.toString().padLeft(digits, '0');
  }

  static bool validate(
    List<int> secret,
    String typed,
    String lecturerId,
    String classKey,
    String localDate,
  ) {
    final clean = typed.trim();
    if (clean.length != digits) return false;
    return _constantTimeEquals(
        derive(secret, lecturerId, classKey, localDate), clean);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff = diff | (a.codeUnitAt(i) ^ b.codeUnitAt(i));
    }
    return diff == 0;
  }
}