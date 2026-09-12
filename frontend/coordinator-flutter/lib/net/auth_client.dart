import '../net/net.dart';

/// Sign-in response from `POST /api/v1/auth/app-login` — the UNIFIED KIU QAAT
/// login for every role. Mirrors the gateway's auth_applogin.go augmentation:
/// on top of the auth-service `loginResponse` it carries the student's
/// registration number and the lecturer's/patroller's staff id, which the
/// coordinator-flutter port routes by role.
class LoginResult {
  const LoginResult({
    required this.token,
    required this.role,
    required this.userId,
    required this.tenantId,
    this.fullName = '',
    this.title = '',
    this.registrationNo = '',
    this.studentId = '',
    this.staffId = '',
    this.deviceBindingKey,
    this.forcePasswordChange = false,
  });

  factory LoginResult.fromJson(Map<String, dynamic> j) {
    final bindingKey = (j['device_binding_key'] as String?) ?? '';
    return LoginResult(
      token: (j['access_token'] ?? '') as String,
      role: (j['role'] ?? '') as String,
      userId: (j['user_id'] ?? '') as String,
      tenantId: (j['tenant_id'] ?? '') as String,
      fullName: (j['full_name'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      registrationNo: (j['registration_number'] ?? '') as String,
      studentId: (j['student_id'] ?? '') as String,
      staffId: (j['staff_id'] ?? '') as String,
      deviceBindingKey: bindingKey.isEmpty ? null : bindingKey,
      forcePasswordChange: (j['force_password_change'] ?? false) as bool,
    );
  }

  /// The server field names, so a saved session round-trips through the same API
  /// shape and a future backend that returns more fields keeps working.
  Map<String, dynamic> toJson() => {
        'access_token': token,
        'role': role,
        'user_id': userId,
        'tenant_id': tenantId,
        'full_name': fullName,
        'title': title,
        'registration_number': registrationNo,
        'student_id': studentId,
        'staff_id': staffId,
        if (deviceBindingKey != null) 'device_binding_key': deviceBindingKey,
        'force_password_change': forcePasswordChange,
      };

  final String token;
  final String role;
  final String userId;
  final String tenantId;
  final String fullName;
  final String title;
  final String registrationNo;
  final String studentId;
  final String staffId;

  /// Server-issued coordinator device binding key (`device_binding_key`) — the
  /// secret the session-package Sealer derives its AES/HMAC keys from. Keep it in
  /// memory only; never log it.
  final String? deviceBindingKey;

  /// True when the account still signs in with its seeded default password; the
  /// app must force a change before showing any role UI.
  final bool forcePasswordChange;

  /// Best display name: the credential's full name, else the identifier's local part.
  String displayName(String identifier) =>
      fullName.isNotEmpty ? fullName : identifier.split('@').first;
}

/// Login / credential helpers hitting the gateway's public auth routes.
class AuthClient {
  const AuthClient();

  /// POST /api/v1/auth/app-login  (public, rate-limited, 429 back-off in `Net`).
  ///
  /// [identifier] = email (staff/coordinator) OR registration number (student) OR
  /// staff ID (lecturer). Returns the signed-in [LoginResult]; on the server's
  /// `403 {error: MFA_REQUIRED}` it returns null and the caller should show the
  /// TOTP field and submit again with [totp] populated.
  Future<LoginResult?> appLogin(
    String identifier,
    String password, {
    String? totp,
  }) async {
    try {
      final j = await Net.postJson(
        '/api/v1/auth/app-login',
        body: {
          'identifier': identifier.trim(),
          'password': password,
          if (totp != null && totp.isNotEmpty) 'totp_code': totp.trim(),
        },
      ) as Map<String, dynamic>;
      return LoginResult.fromJson(j);
    } on NetFailure catch (e) {
      if (e.isMfaRequired) return null;
      rethrow;
    }
  }

  /// POST /api/v1/auth/change-password — the signed-in user changes their own
  /// password. Returns the server's refusal message, or null on success.
  Future<String?> changePassword(
    String token,
    String current,
    String newPassword,
  ) async {
    try {
      await Net.postJson(
        '/api/v1/auth/change-password',
        token: token,
        body: {'current_password': current, 'new_password': newPassword},
      );
      return null;
    } on NetFailure catch (e) {
      return e.message;
    }
  }
}