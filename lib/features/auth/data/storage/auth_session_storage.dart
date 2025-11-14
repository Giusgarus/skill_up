import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/auth_api.dart';

/// Persist and restore the active auth session across app launches.
class AuthSessionStorage {
  AuthSessionStorage({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _tokenKey = 'auth_token';
  static const _usernameKey = 'auth_username';
  static bool _secureStorageDisabled = false;
  static bool _secureFailureLogged = false;
  final FlutterSecureStorage _secureStorage;

  /// Save the latest session to disk.
  Future<void> saveSession(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    var storedSecurely = false;
    if (!_secureStorageDisabled) {
      try {
        await _secureStorage.write(key: _tokenKey, value: session.token);
        storedSecurely = true;
      } on PlatformException catch (error, stackTrace) {
        _handleSecureFailure('write token', error, stackTrace);
      } catch (error, stackTrace) {
        _handleSecureFailure('write token', error, stackTrace);
      }
    }
    if (storedSecurely) {
      await prefs.remove(_tokenKey); // remove legacy token if present
    } else {
      await prefs.setString(_tokenKey, session.token);
    }
    await prefs.setString(_usernameKey, session.username);
  }

  /// Load a previously stored session, if present.
  Future<AuthSession?> readSession() async {
    final prefs = await SharedPreferences.getInstance();
    String? token;
    var secureReadFailed = false;
    if (!_secureStorageDisabled) {
      try {
        token = await _secureStorage.read(key: _tokenKey);
      } on PlatformException catch (error, stackTrace) {
        secureReadFailed = true;
        _handleSecureFailure('read token', error, stackTrace);
      } catch (error, stackTrace) {
        secureReadFailed = true;
        _handleSecureFailure('read token', error, stackTrace);
      }
    } else {
      secureReadFailed = true;
    }
    if (token == null) {
      final legacyToken = prefs.getString(_tokenKey);
      if (legacyToken != null) {
        token = legacyToken;
        if (!secureReadFailed) {
          try {
            await _secureStorage.write(key: _tokenKey, value: legacyToken);
            await prefs.remove(_tokenKey);
          } on PlatformException catch (error, stackTrace) {
            _handleSecureFailure('migrate token', error, stackTrace);
          } catch (error, stackTrace) {
            _handleSecureFailure('migrate token', error, stackTrace);
          }
        }
      }
    }
    final username = prefs.getString(_usernameKey);
    if (token == null || username == null) {
      return null;
    }
    return AuthSession(token: token, username: username);
  }

  /// Remove any persisted session when logging out.
  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_secureStorageDisabled) {
      try {
        await _secureStorage.delete(key: _tokenKey);
      } on PlatformException catch (error, stackTrace) {
        _handleSecureFailure('delete token', error, stackTrace);
      } catch (error, stackTrace) {
        _handleSecureFailure('delete token', error, stackTrace);
      }
    }
    await prefs.remove(_tokenKey);
    await prefs.remove(_usernameKey);
  }

  void _handleSecureFailure(
    String action,
    Object error,
    StackTrace stackTrace,
  ) {
    _secureStorageDisabled = true;
    if (!kDebugMode || _secureFailureLogged) {
      return;
    }
    _secureFailureLogged = true;
    debugPrint('AuthSessionStorage: unable to $action securely: $error');
    debugPrint(stackTrace.toString());
  }
}
