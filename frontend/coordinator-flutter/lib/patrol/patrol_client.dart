import 'dart:convert';

import 'package:http/http.dart' as http;

import '../patrol/patrol_models.dart';
import '../net/net.dart';

/// Raised when the gateway rejects this handset. Carries the message the monitor
/// should see.
class PatrolDeviceRejected implements Exception {
  PatrolDeviceRejected(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// What the PIN screen should show: set it, ask for it, or report the lockout.
class PinState {
  const PinState(this.isSet, this.locked, this.lockedUntil, this.attemptsLeft);
  final bool isSet;
  final bool locked;
  final String lockedUntil;
  final int attemptsLeft;
}

/// Result of a verify attempt: ok = the round may open.
class PinAttempt {
  const PinAttempt(this.ok, this.message, this.attemptsLeft, this.locked);
  final bool ok;
  final String message;
  final int attemptsLeft;
  final bool locked;
}

/// The QA monitor's cloud calls: claim this handset, pull today's timetable, push
/// the round. A faithful port of the native `PatrolClient`.
///
/// Every call carries `X-Device-Fingerprint` (via [Net.getJson]/[Net.postJson]
/// where used). A monitor record accuses a named lecturer of not having taught, so
/// the gateway accepts one only from the handset the monitor claimed — a stolen or
/// shared token replayed from another phone is refused with `DEVICE_NOT_BOUND`,
/// surfaced here as [PatrolDeviceRejected].
class PatrolClient {
  /// Claim this handset for the signed-in monitor. First call binds; later calls
  /// from the SAME phone are a no-op confirmation; a different phone is refused
  /// until an admin releases the binding. Returns null when the server accepted it,
  /// else the message to show. Network failure propagates (the caller decides
  /// whether that is "offline" rather than "your phone").
  Future<String?> bindDevice(String token, String fingerprint) async {
    final r = await Net.retrying(() => Net.shared.post(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/bind-device'),
          headers: _headers(token, fingerprint),
          body: jsonEncode({'device_fingerprint': fingerprint}),
        ));
    if (r.statusCode >= 200 && r.statusCode < 300) return null;
    return _messageOf(r) ??
        'This phone is not authorised for monitoring (${r.statusCode}).';
  }

  /// GET /api/v1/patrol/pin — what the PIN gate should show. Null on any failure,
  /// which the gate reads as "can't check right now, needs a connection".
  Future<PinState?> pinState(String token) async {
    try {
      final o = await Net.getJson('/api/v1/patrol/pin', token: token)
          as Map<String, dynamic>;
      return PinState(
        (o['pin_set'] ?? false) as bool,
        (o['locked'] ?? false) as bool,
        (o['locked_until'] ?? '') as String,
        ((o['attempts_left'] ?? 5) as num).toInt(),
      );
    } on Object {
      return null;
    }
  }

  /// Set the PIN (first time) or change it (with [currentPin]). Returns null on
  /// success, else a message to show.
  Future<String?> setPin(String token, String pin, {String? currentPin}) async {
    try {
      final r = await Net.retrying(() => Net.shared.post(
            Uri.parse('${Net.baseUrl}/api/v1/patrol/pin'),
            headers: _headers(token),
            body: jsonEncode({
              'pin': pin,
              if (currentPin != null && currentPin.isNotEmpty)
                'current_pin': currentPin,
            }),
          ));
      if (r.statusCode >= 200 && r.statusCode < 300) return null;
      return _messageOf(r) ?? "Couldn't save your PIN.";
    } on Object {
      return "Couldn't reach the server. You need to be online to set your PIN.";
    }
  }

  /// POST /api/v1/patrol/pin/verify — the PIN is verified SERVER-side on purpose,
  /// so a locally-checkable secret on a stolen handset is no secret. Being offline
  /// therefore means the round cannot open, and the monitor is told plainly.
  Future<PinAttempt> verifyPin(String token, String pin) async {
    if (token.isEmpty) {
      return const PinAttempt(
          false, 'Your session has ended. Sign in again.', 0, false);
    }
    try {
      final r = await Net.retrying(() => Net.shared.post(
            Uri.parse('${Net.baseUrl}/api/v1/patrol/pin/verify'),
            headers: _headers(token),
            body: jsonEncode({'pin': pin}),
          ));
      if (r.statusCode >= 200 && r.statusCode < 300) {
        return const PinAttempt(true, '', 5, false);
      }
      final o = _json(r);
      return PinAttempt(
        false,
        ((o?['message'] as String?)?.isNotEmpty ?? false)
            ? o!['message'] as String
            : 'That PIN is not right.',
        ((o?['attempts_left'] ?? 0) as num).toInt(),
        o?['error'] == 'PIN_LOCKED',
      );
    } on Object {
      return const PinAttempt(
          false,
          'You need to be online to unlock monitoring. Find signal and try again.',
          0,
          false);
    }
  }

  /// GET /api/v1/patrol/manifest — the timetabled slots for the whole week (the
  /// phone filters to today and caches the rest). Throws [PatrolDeviceRejected] on
  /// a 403 so the caller can say THIS phone is refused.
  Future<List<PatrolSlot>> manifest(String token, String fingerprint) async {
    final r = await Net.retrying(() => Net.shared.get(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/manifest'),
          headers: _headers(token, fingerprint),
        ));
    if (r.statusCode == 403) throw _deviceRejected(r);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NetFailure(r.statusCode, '', 'manifest fetch failed (${r.statusCode})');
    }
    final arr = _json(r)?['slots'] as List? ?? const [];
    return arr
        .whereType<Map<String, dynamic>>()
        .map(PatrolSlot.fromJson)
        .where((s) => s.unitId.isNotEmpty && s.startTime.isNotEmpty)
        .toList();
  }

  /// GET /api/v1/patrol/search?by=lecturer|unit&q=…
  ///
  /// The round shows nothing until this returns something — a tick is evidence of
  /// having VISITED a room. Returns null when offline (the caller falls back to the
  /// cached day, with a different message from "nobody by that name").
  Future<List<PatrolSlot>?> search(
      String token, String fingerprint, String mode, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final http.Response r;
    try {
      r = await Net.retrying(() => Net.shared.get(
            Uri.parse(
                '${Net.baseUrl}/api/v1/patrol/search?by=$mode&q=${Uri.encodeQueryComponent(q)}'),
            headers: _headers(token, fingerprint),
          ));
    } on Object {
      // Offline — the caller searches the cache.
      return null;
    }
    if (r.statusCode == 403) throw _deviceRejected(r);
    if (r.statusCode < 200 || r.statusCode >= 300) return null;
    final arr = _json(r)?['results'] as List? ?? const [];
    return arr
        .whereType<Map<String, dynamic>>()
        .map(PatrolSlot.fromJson)
        .where((s) => s.unitId.isNotEmpty)
        .toList();
  }

  /// POST /api/v1/patrol/sync {logs:[…]} — true once the batch is durably stored.
  Future<bool> sync(
      String token, String fingerprint, List<PatrolLog> logs) async {
    if (logs.isEmpty) return true;
    final r = await Net.retrying(() => Net.shared.post(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/sync'),
          headers: _headers(token, fingerprint),
          body: jsonEncode({'logs': logs.map((l) => l.toSyncJson()).toList()}),
        ));
    if (r.statusCode == 403) throw _deviceRejected(r);
    return r.statusCode >= 200 && r.statusCode < 300;
  }

  /// GET /api/v1/patrol/reference — the pick-lists, in ONE call so the manual form
  /// cannot half-load. Empty on failure (offline corridor).
  Future<PatrolReference> reference(String token, String fingerprint) async {
    try {
      final o = await Net.getJson('/api/v1/patrol/reference',
          token: token, fingerprint: fingerprint) as Map<String, dynamic>;
      return PatrolReference.fromJson(o);
    } on Object {
      return const PatrolReference();
    }
  }

  /// POST /api/v1/patrol/manual — file a lecture that is not on the timetable.
  /// Sent immediately rather than queued (the one record nobody else has must not
  /// be the most likely to be lost). Returns the server's message on refusal so the
  /// form can say WHICH field it wants; null on success.
  Future<String?> manual(String token, String fingerprint, ManualEntry e) async {
    final r = await Net.retrying(() => Net.shared.post(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/manual'),
          headers: _headers(token, fingerprint),
          body: jsonEncode(e.toJson()),
        ));
    if (r.statusCode == 403) throw _deviceRejected(r);
    if (r.statusCode >= 200 && r.statusCode < 300) return null;
    return _messageOf(r) ?? 'Could not record it (${r.statusCode})';
  }

  /// GET /api/v1/patrol/office/manifest — the employee registry, cached for the
  /// round so the search works with no signal.
  Future<List<OfficePerson>> officeManifest(
      String token, String fingerprint) async {
    final r = await Net.retrying(() => Net.shared.get(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/office/manifest'),
          headers: _headers(token, fingerprint),
        ));
    if (r.statusCode == 403) throw _deviceRejected(r);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NetFailure(
          r.statusCode, '', 'office manifest fetch failed (${r.statusCode})');
    }
    return _officePeopleOf(_json(r)?['employees']);
  }

  /// GET /api/v1/patrol/office/search?q=… — null when offline (caller MUST
  /// distinguish "no signal" from "nobody by that name works here").
  Future<List<OfficePerson>?> officeSearch(
      String token, String fingerprint, String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final http.Response r;
    try {
      r = await Net.retrying(() => Net.shared.get(
            Uri.parse(
                '${Net.baseUrl}/api/v1/patrol/office/search?q=${Uri.encodeQueryComponent(q)}'),
            headers: _headers(token, fingerprint),
          ));
    } on Object {
      return null;
    }
    if (r.statusCode == 403) throw _deviceRejected(r);
    if (r.statusCode < 200 || r.statusCode >= 300) return null;
    return _officePeopleOf(_json(r)?['results']);
  }

  /// POST /api/v1/patrol/office/sync {visits:[…]} — true once durably stored. The
  /// server keys on visit_id, so a re-sent batch updates in place, never duplicates.
  Future<bool> officeSync(
      String token, String fingerprint, List<OfficeVisit> visits) async {
    if (visits.isEmpty) return true;
    final r = await Net.retrying(() => Net.shared.post(
          Uri.parse('${Net.baseUrl}/api/v1/patrol/office/sync'),
          headers: _headers(token, fingerprint),
          body: jsonEncode({'visits': visits.map((v) => v.toSyncJson()).toList()}),
        ));
    if (r.statusCode == 403) throw _deviceRejected(r);
    return r.statusCode >= 200 && r.statusCode < 300;
  }

  // ── shared helpers ──────────────────────────────────────────────────────────

  static Map<String, String> _headers(String token, [String? fingerprint]) => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (fingerprint != null && fingerprint.isNotEmpty)
          'X-Device-Fingerprint': fingerprint,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

  static Map<String, dynamic>? _json(http.Response r) {
    try {
      final o = jsonDecode(r.body);
      return o is Map<String, dynamic> ? o : null;
    } on Object {
      return null;
    }
  }

  static String? _messageOf(http.Response r) {
    final msg = _json(r)?['message'] as String?;
    return (msg != null && msg.isNotEmpty) ? msg : null;
  }

  static PatrolDeviceRejected _deviceRejected(http.Response r) =>
      PatrolDeviceRejected(_messageOf(r) ??
          'This phone is not the one registered for your monitor account.');

  /// Both office endpoints return the same person shape.
  static List<OfficePerson> _officePeopleOf(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((o) {
          final staffId = (o['staff_id'] ?? '') as String;
          if (staffId.isEmpty) return null;
          return OfficePerson(
            staffId: staffId,
            fullName: (o['full_name'] ?? staffId) as String,
            department: (o['department'] ?? '') as String,
            jobTitle: (o['job_title'] ?? '') as String,
            office: (o['office'] ?? '') as String,
          );
        })
        .whereType<OfficePerson>()
        .toList();
  }
}