import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/medal_utils.dart';

/// Persists daily task completion flags keyed by date.
class DailyTaskCompletionStorage {
  DailyTaskCompletionStorage._();

  static final DailyTaskCompletionStorage instance =
      DailyTaskCompletionStorage._();

  static const _storageKey = 'daily_task_completion_v1';
  static const Map<String, String> _legacyTaskIdMap = {
    'drink-water': '1',
    'walking': '2',
    'stretching': '3',
    'stretching2': '4',
    'stretching3': '5',
    'stretching4': '6',
  };

  Future<Map<String, dynamic>> _readRaw() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    if (jsonString == null) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeRaw(Map<String, dynamic> raw) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(raw));
  }

  String _dayKey(DateTime day) {
    final normalized = dateOnly(day);
    final month = normalized.month.toString().padLeft(2, '0');
    final dayNumber = normalized.day.toString().padLeft(2, '0');
    return '${normalized.year}-$month-$dayNumber';
  }

  Map<String, bool> _deserializeDay(dynamic value) {
    final result = <String, bool>{};
    if (value is Map) {
      value.forEach((key, dynamic val) {
        final taskId = key.toString();
        final normalizedId = _legacyTaskIdMap[taskId] ?? taskId;
        if (val is bool) {
          result[normalizedId] = val;
        } else if (val is num) {
          result[normalizedId] = val != 0;
        } else if (val is String) {
          result[normalizedId] = val.toLowerCase() == 'true' || val == '1';
        }
      });
    }
    return result;
  }

  Map<String, dynamic> _userMap(Map<String, dynamic> root, String username) {
    final rawUser = root[username];
    if (rawUser is Map<String, dynamic>) {
      return rawUser;
    }
    if (rawUser is Map) {
      return rawUser.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{};
  }

  Future<Map<String, bool>> loadForDay(DateTime day, String username) async {
    final root = await _readRaw();
    final userMap = _userMap(root, username);
    final key = _dayKey(day);
    return _deserializeDay(userMap[key]);
  }

  Future<Map<DateTime, Map<String, bool>>> loadMonth(
    DateTime anchor,
    String username,
  ) async {
    final root = await _readRaw();
    final userMap = _userMap(root, username);
    final result = <DateTime, Map<String, bool>>{};
    final targetYear = anchor.year;
    final targetMonth = anchor.month;
    userMap.forEach((key, value) {
      try {
        final parsed = DateTime.parse(key);
        if (parsed.year == targetYear && parsed.month == targetMonth) {
          result[dateOnly(parsed)] = _deserializeDay(value);
        }
      } catch (_) {
        // ignore invalid entries
      }
    });
    return result;
  }

  Future<void> setTaskStatus(
    DateTime day,
    String taskId,
    bool isCompleted,
    String username,
  ) async {
    final root = await _readRaw();
    final userMap = _userMap(root, username);
    final key = _dayKey(day);
    final current = _deserializeDay(userMap[key]);
    final normalizedId = _legacyTaskIdMap[taskId] ?? taskId;
    current[normalizedId] = isCompleted;
    userMap[key] = current;
    root[username] = userMap;
    await _writeRaw(root);
  }
}
