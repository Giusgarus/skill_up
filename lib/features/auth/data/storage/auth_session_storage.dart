import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_api.dart';

/// Persist and restore the active auth session across app launches.
class AuthSessionStorage {
  static const _tokenKey = 'auth_token';
  static const _usernameKey = 'auth_username';

  /// Save the latest session to disk.
  Future<void> saveSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, session.token);
    await prefs.setString(_usernameKey, session.username);
  }

  /// Load a previously stored session, if present.
  Future<AuthSession?> readSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final username = prefs.getString(_usernameKey);
    if (token == null || username == null) {
      return null;
    }
    return AuthSession(token: token, username: username);
  }

  /// Remove any persisted session when logging out.
  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_usernameKey);
  }
}
