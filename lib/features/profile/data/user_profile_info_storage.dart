import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Handles persistence of textual user profile information.
class UserProfileInfoStorage {
  UserProfileInfoStorage._();

  static final UserProfileInfoStorage instance = UserProfileInfoStorage._();

  static const _storageKey = 'user_profile_fields_v1';

  Future<Map<String, dynamic>> _readRoot() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_storageKey);
    if (stored == null || stored.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeRoot(Map<String, dynamic> root) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(root));
  }

  Map<String, String> _deserializeUser(dynamic value) {
    if (value is Map) {
      return value.map<String, String>(
        (key, val) => MapEntry(key.toString(), val?.toString() ?? ''),
      );
    }
    return <String, String>{};
  }

  Future<Map<String, String>> loadAllFields(String username) async {
    final root = await _readRoot();
    return _deserializeUser(root[username]);
  }

  Future<void> setField(String username, String fieldId, String value) async {
    final root = await _readRoot();
    final current = _deserializeUser(root[username]);
    current[fieldId] = value;
    root[username] = current;
    await _writeRoot(root);
  }

  Future<void> setFields(String username, Map<String, String> fields) async {
    if (fields.isEmpty) {
      return;
    }
    final root = await _readRoot();
    final current = _deserializeUser(root[username]);
    current.addAll(fields);
    root[username] = current;
    await _writeRoot(root);
  }

  Future<void> clear(String username) async {
    final root = await _readRoot();
    if (root.containsKey(username)) {
      root.remove(username);
      await _writeRoot(root);
    }
  }
}
