import 'dart:convert';

import 'package:http/http.dart' as http;

/// QAAT mobile API client. Talks to the Go backend's per-role API groups.
///
/// Attendance endpoints return 501 "attendance logic pending merge" until the
/// engine merges in (spec doc 06). [ApiException.isPendingMerge] lets screens
/// render the pending state instead of a hard error.
class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  /// True when the backend signals the attendance merge slot (HTTP 501).
  bool get isPendingMerge => status == 501;

  /// True when the token is missing/invalid (HTTP 401).
  bool get isUnauthorized => status == 401;

  @override
  String toString() => message;
}

class User {
  User({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.emailVerified,
    required this.registrationNumber,
  });

  final String id;
  final String email;
  final String fullName;
  final String role;
  final bool emailVerified;
  final String? registrationNumber;

  bool get isStudent => role == 'student';
  bool get isLecturer => role == 'lecturer' || role == 'kiu_admin';

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String? ?? '',
        email: j['email'] as String? ?? '',
        fullName: j['fullName'] as String? ?? '',
        role: j['role'] as String? ?? 'student',
        emailVerified: j['emailVerified'] as bool? ?? false,
        registrationNumber: j['registrationNumber'] as String?,
      );
}

class ApiClient {
  ApiClient({String? baseUrl}) : baseUrl = baseUrl ?? defaultBaseUrl;

  /// Overridable at build time: --dart-define=QAAT_API_URL=...
  static const String defaultBaseUrl =
      String.fromEnvironment('QAAT_API_URL', defaultValue: 'http://localhost:8080');

  final String baseUrl;
  String? _token;

  void setToken(String? t) => _token = t;
  String? get token => _token;

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  Future<dynamic> _requestRaw(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final req = http.Request(method, uri);
    req.headers.addAll(_headers());
    if (body != null) req.body = jsonEncode(body);

    late http.Response res;
    try {
      res = await http.Response.fromStream(
        await req.send().timeout(const Duration(seconds: 20)),
      );
    } on Exception {
      throw ApiException(0, 'Could not reach the server.');
    }

    final text = utf8.decode(res.bodyBytes);
    final dynamic json = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);

    if (res.statusCode >= 400) {
      final map = json is Map<String, dynamic> ? json : <String, dynamic>{};
      final detail = (map['detail'] ?? map['error'] ?? 'Request failed') as String;
      throw ApiException(res.statusCode, detail);
    }
    return json;
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final dynamic json = await _requestRaw(path, method: method, body: body);
    if (json is Map<String, dynamic>) return json;
    return <String, dynamic>{'data': json};
  }

  // --- auth (spec doc 05) ---

  Future<User> login(String login, String password) async {
    final j = await _request(
      '/api/auth/login',
      method: 'POST',
      body: {'login': login.trim(), 'password': password},
    );
    _token = j['token'] as String?;
    return User.fromJson(j['user'] as Map<String, dynamic>);
  }

  Future<User> register({
    required String email,
    required String password,
    required String fullName,
    required String registrationNumber,
  }) async {
    final j = await _request(
      '/api/auth/register',
      method: 'POST',
      body: {
        'email': email.trim(),
        'password': password,
        'full_name': fullName.trim(),
        'registration_number': registrationNumber.trim(),
      },
    );
    _token = j['token'] as String?;
    return User.fromJson(j['user'] as Map<String, dynamic>);
  }

  Future<User> me() async {
    final j = await _request('/api/auth/me');
    return User.fromJson(j);
  }

  // --- dashboards ---
  //
  // No student dashboard: per spec doc 07 students navigate Attendance ·
  // Notices · Profile, so /api/student/dashboard is never called from here.

  Future<Map<String, dynamic>> lecturerDashboard() =>
      _request('/api/lecturer/dashboard');

  // --- attendance surface (501 until merge) ---

  /// Backs [AttendanceView]. While the engine is the merge slot the backend
  /// answers 501 and the screen renders the pending state instead of an error.
  Future<List<dynamic>> lists(String group) async {
    final dynamic j = await _requestRaw('/api/$group/lists');
    return j is List ? j : const [];
  }
}
