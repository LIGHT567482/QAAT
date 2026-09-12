import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Backend base URL + the shared HTTP client, mirroring the Android app's `Net.kt`.
///
/// The URL is switchable at RUNTIME (`Net.setBaseUrl`, e.g. the login screen's server
/// field), defaulting to the compiled-in cloud URL. The in-room hub and the LAN test
/// server are reachable through the same helper by pointing it at their address — no
/// rebuild needed.
///
/// One shared client, not one per call: building a fresh client on every screen on
/// Android leaked sockets/file descriptors, and the same reasoning applies here.
class Net {
  Net._();

  /// Effective backend URL: a runtime override if set, else the default cloud gateway.
  static String baseUrl = _defaultBaseUrl;

  /// The cloud gateway — THE SAME default the native coordinator-android app ships
  /// (its `BuildConfig.API_BASE`), so both builds talk to one server. Build-time
  /// override: `flutter build apk --release --dart-define=API_BASE=…`.
  static const String _defaultBaseUrl = String.fromEnvironment(
      'API_BASE', defaultValue: 'https://kiu-qaat-gateway.onrender.com');

  /// The auth-service's own health URL, pinged by [warmUp] to wake the sleeping
  /// free-tier service BEFORE the user submits (the gateway proxies login to it).
  static const String _authWarmUrl = String.fromEnvironment(
      'AUTH_WARM_URL', defaultValue: 'https://kiu-qaat-auth.onrender.com/health');

  static void setBaseUrl(String? url) {
    final clean = url?.trim().replaceFirst(RegExp(r'/+$'), '');
    baseUrl = (clean == null || clean.isEmpty) ? _defaultBaseUrl : clean;
  }

  /// ONE shared client. The base URL is passed per-request (full URL), so runtime
  /// server switching still works. Assignable for tests (a `MockClient`).
  static http.Client shared = http.Client();

  /// Best-effort pings to wake the sleeping free-tier backend BEFORE the user submits,
  /// so the cold start overlaps with typing instead of stalling sign-in. Hits BOTH the
  /// auth-service (the actual sleeper login is proxied to) and the gateway. Failures
  /// are ignored.
  static Future<void> warmUp() async {
    try {
      await shared.get(Uri.parse(_authWarmUrl));
    } catch (_) {}
    try {
      await shared.get(Uri.parse('$baseUrl/health'));
    } catch (_) {}
  }

  /// Run [send], and when the server answers 429 wait as it asked and try again.
  ///
  /// A whole institution shares one public IP on campus Wi-Fi, so the gateway's per-IP
  /// limit is in practice a per-CAMPUS limit: when a cohort looks at something together,
  /// the ones at the back are refused for no reason of their own. The server already says
  /// how long to wait — Retry-After exists precisely for this — and a client that ignores
  /// it turns a two-second wait into a failure the student sees. Measured against the
  /// live gateway: a client that gives up got 44% of students their attendance; a client
  /// that backs off got 100%.
  ///
  /// The jitter is not decoration. Without it every refused phone retries in the same
  /// instant and rebuilds the stampede that caused the refusal.
  static Future<http.Response> retrying(
    Future<http.Response> Function() send, {
    int attempts = 4,
  }) async {
    http.Response? last;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final r = await send();
      if (r.statusCode != 429) return r;
      last = r;
      if (attempt == attempts - 1) return r;
      final after = int.tryParse(r.headers['retry-after']?.trim() ?? '');
      final base = (after != null && after > 0 ? after * 1000 : 2000) << min(attempt, 3);
      await Future.delayed(Duration(milliseconds: base + Random().nextInt(base ~/ 2)));
    }
    return last!;
  }

  /// An authenticated JSON GET with the standard 429 back-off. [fingerprint] (the
  /// `X-Device-Fingerprint` header) is stamped on every patrol-family call — see
  /// [LecturerAttendanceClient]. Returns the decoded JSON body on 2xx, else throws a
  /// [NetFailure] whose `statusCode`/`message` the caller can turn into words.
  static Future<dynamic> getJson(
    String path, {
    String token = '',
    String? fingerprint,
  }) async {
    final r = await retrying(() => shared.get(
          Uri.parse(baseUrl + path),
          headers: _authHeaders(token, fingerprint),
        ));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NetFailure(r.statusCode, _serverError(r), _serverMessage(r));
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  /// A JSON POST with the standard 429 back-off. Same contract as [getJson];
  /// returns the decoded body or null for an empty 2xx response. [token] defaults
  /// to '' for the public login routes, which take no bearer token.
  static Future<dynamic> postJson(
    String path, {
    String token = '',
    String? fingerprint,
    Map<String, dynamic>? body,
  }) async {
    final r = await retrying(() => shared.post(
          Uri.parse(baseUrl + path),
          headers: _authHeaders(token, fingerprint),
          body: body == null ? null : jsonEncode(body),
        ));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw NetFailure(r.statusCode, _serverError(r), _serverMessage(r));
    }
    return r.body.isEmpty ? null : jsonDecode(r.body);
  }

  static Map<String, String> _authHeaders(String token, String? fingerprint) {
    return {
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (fingerprint != null && fingerprint.isNotEmpty)
        'X-Device-Fingerprint': fingerprint,
      'Accept': 'application/json',
      if (fingerprint == null) 'Content-Type': 'application/json',
    };
  }

  /// The server's compact machine code (its `error` field, e.g. `MFA_REQUIRED`),
  /// so a screen can branch on WHICH refusal this was rather than matching strings.
  static String _serverError(http.Response r) {
    try {
      final o = jsonDecode(r.body);
      if (o is Map) {
        final e = o['error'];
        if (e is String && e.isNotEmpty) return e;
      }
    } catch (_) {}
    return '';
  }

  /// The server's own message when it refused a call, so the screen can say WHICH
  /// field the handler wanted rather than a bare status code.
  static String _serverMessage(http.Response r) {
    try {
      final o = jsonDecode(r.body);
      if (o is Map) {
        final m = o['message'];
        if (m is String && m.isNotEmpty) return m;
      }
    } catch (_) {}
    return 'The server refused the request (${r.statusCode}).';
  }

  /// Turn a raw network exception into a calm, human message — no "SocketTimeout
  /// (0.000s)" jargon leaking to coordinators.
  static String friendly(Object error) {
    final m = '${error is Error ? error.toString() : error}'.toLowerCase();
    return switch (error) {
      NetFailure f => f.message,
      _ when m.contains('timeout') || m.contains('timed out') =>
        'The server is waking up (it sleeps when idle). Please wait a few seconds and tap again.',
      _ when m.contains('unable to resolve') || m.contains('failed to connect') ||
          m.contains('unreachable') || m.contains('connection refused') =>
        "Can't reach the server — check your internet connection and try again.",
      _ when m.contains('certificate') || m.contains('ssl') || m.contains('handshake') =>
        'Secure connection failed. Set your phone to automatic date & time, then try again.',
      _ => error.toString().length < 120
          ? error.toString()
          : 'Something went wrong. Please try again.',
    };
  }
}

/// The gateway refused a request. [statusCode] is the HTTP code, [code] the
/// server's compact machine code (`error`, e.g. `MFA_REQUIRED`) when present, and
/// [message] the server's own words (field-level guidance for a form, a reason for
/// a 403) when it supplied any.
class NetFailure implements Exception {
  NetFailure(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;

  bool get isMfaRequired => code == 'MFA_REQUIRED';

  @override
  String toString() => 'NetFailure($statusCode): $message';
}