import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// Persists the auth token and caches the last-known user for cold-start
/// session restore (spec doc 05 §8: restore-session on cold start).
class AuthRepository {
  AuthRepository(this.api);
  final ApiClient api;

  static const _kToken = 'qaat_token';
  static const _kUserId = 'qaat_user_id';
  static const _kRole = 'qaat_role';

  /// Attempts to restore a previous session. Returns the restored user, or
  /// null when there is no valid token / the token was revoked.
  Future<User?> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kToken);
    if (token == null || token.isEmpty) return null;
    api.setToken(token);
    try {
      final user = await api.me();
      await _cacheUser(user);
      return user;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await clear();
        return null;
      }
      // Network error: keep the token, fall back to the cached identity.
      final cachedId = prefs.getString(_kUserId);
      final cachedRole = prefs.getString(_kRole);
      if (cachedId == null || cachedRole == null) return null;
      return User(
        id: cachedId,
        email: '',
        fullName: '',
        role: cachedRole,
        emailVerified: true,
        registrationNumber: null,
      );
    }
  }

  Future<void> saveSession(String token, User user) async {
    api.setToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, token);
    await _cacheUser(user);
  }

  Future<void> _cacheUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserId, user.id);
    await prefs.setString(_kRole, user.role);
  }

  Future<void> clear() async {
    api.setToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUserId);
    await prefs.remove(_kRole);
  }
}
