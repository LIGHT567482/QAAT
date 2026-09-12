import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// The stable per-device fingerprint sent as `X-Device-Fingerprint` on every
/// QA-monitor patrol call.
///
/// Mirrors the native `Fingerprint.get()` byte-for-byte: the hex SHA-256 of
/// `"qaat-student|<ANDROID_ID>|<Build.MODEL>"`. The ANDROID_ID and model are read
/// from the host via the `qaat/device` MethodChannel added in `MainActivity.kt`
/// (Dart has no access to `Settings.Secure`), and the hashing happens HERE with
/// the `crypto` package so the recipe is testable on the host without a device.
///
/// A device-lifted token is the threat this header exists to neutralise: the
/// gateway stores the first fingerprint it sees for a monitor account and refuses
/// calls from any other handset (`DEVICE_NOT_BOUND`).
class DeviceFingerprint {
  DeviceFingerprint._();

  static const MethodChannel _channel = MethodChannel('qaat/device');

  /// Thread-safe override for tests / host-side runs — when set, [get] returns it
  /// verbatim and never touches the platform channel.
  static String? testOverride;

  /// Live value, computed exactly like the native app. Worst case (channel
  /// missing/unroutable, e.g. in a widget test without the override) degrades to a
  /// device-independent hash of the environment — still a stable per-session value,
  /// never readable as real device identity.
  static Future<String> get() async {
    final override = testOverride;
    if (override != null) return override;
    try {
      final facts =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceFacts');
      final androidId = '${facts?['androidId'] ?? ''}';
      final model = '${facts?['model'] ?? ''}';
      return _sha256Hex('qaat-student|$androidId|$model');
    } on MissingPluginException {
      // Host-side (tests / desktop): keep it deterministic for the process.
      return _sha256Hex('qaat-student||host');
    }
  }

  static String _sha256Hex(String s) =>
      sha256.convert(utf8.encode(s)).toString();
}