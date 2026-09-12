import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'auth_client.dart';

/// The persistent sign-in: the app boots straight to the signed-in hub instead of
/// asking for credentials again on every launch of the working day.
///
/// One thing is stored: the [LoginResult] itself (the token + the account facts
/// the hub routes on). The app is LIGHT theme only.
///
/// Storing a bearer token on disk is a security decision, made deliberately:
/// losing the day's work because an app refused to remember who it is signed in
/// as is the offline-tolerant behaviour this build exists for. The token is the
/// phone's own credential the way the Android keystore-bound session is, and
/// clearing it (sign-out) is a single explicit action from any role.
class SessionStore {
  SessionStore._();

  static const _sessionKey = 'qaat.saved_session';

  /// Save the signed-in session so the next launch boots into the hub.
  /// Best-effort: an unpersistable session must never block the sign-in itself.
  static Future<void> save(LoginResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(result.toJson()));
    } on Object {
      // Sign-in proceeds without persistence; the next launch just asks again.
    }
  }

  /// The saved session, or null when nobody has signed in (or the value is
  /// corrupt — a corrupt token is safer dropped than booted).
  static Future<LoginResult?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final r = LoginResult.fromJson(j);
      return r.token.isNotEmpty && r.role.isNotEmpty ? r : null;
    } on Object {
      return null;
    }
  }

  /// Sign-out from any role clears the saved session.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } on Object {
      // Nothing else to do — a signed-out phone is what we leave it as.
    }
  }
}