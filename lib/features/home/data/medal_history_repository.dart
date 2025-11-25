import 'package:flutter/material.dart';

import '../domain/medal_utils.dart';

/// Centralized storage for medals earned by day.
class MedalHistoryRepository {
  MedalHistoryRepository._();

  static final MedalHistoryRepository instance = MedalHistoryRepository._();

  static const int defaultDailyTaskCount = 6;

  final Map<String, Map<DateTime, MedalType>> _medalsByUser =
      <String, Map<DateTime, MedalType>>{};
  String? _activeUser;

  void setActiveUser(String username) {
    _activeUser = username;
    _medalsByUser.putIfAbsent(username, () => <DateTime, MedalType>{});
  }

  void clearForUser(String username) {
    _medalsByUser.remove(username);
    if (_activeUser == username) {
      _activeUser = null;
    }
  }

  Map<DateTime, MedalType> _ensureMap() {
    final user = _activeUser ?? '__default__';
    return _medalsByUser.putIfAbsent(user, () => <DateTime, MedalType>{});
  }

  /// Returns medals for every day in the provided [month].
  Map<DateTime, MedalType> medalsForMonth(DateTime month) {
    final medals = _ensureMap();
    final monthStart = DateTime(month.year, month.month);
    final daysInMonth =
        DateUtils.getDaysInMonth(monthStart.year, monthStart.month);
    final map = <DateTime, MedalType>{};

    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(monthStart.year, monthStart.month, day);
      map[date] = medals[date] ?? MedalType.none;
    }

    return map;
  }

  /// Returns medals for an entire [year], ensuring a month seed exists.
  Map<DateTime, MedalType> medalsForYear(int year,
      {int totalTasksPerDay = defaultDailyTaskCount}) {
    final map = <DateTime, MedalType>{};
    for (var month = 1; month <= 12; month++) {
      final date = DateTime(year, month);
      map.addAll(medalsForMonth(date));
    }
    return map;
  }

  /// Returns the stored medal for [day], defaulting to [MedalType.none].
  MedalType medalForDay(DateTime day) {
    final normalized = dateOnly(day);
    final medals = _ensureMap();
    return medals[normalized] ?? MedalType.none;
  }

  bool hasMedalForDay(DateTime day) {
    final medals = _ensureMap();
    return medals.containsKey(dateOnly(day));
  }

  bool hasAnyForMonth(DateTime month) {
    final monthStart = DateTime(month.year, month.month);
    final daysInMonth =
        DateUtils.getDaysInMonth(monthStart.year, monthStart.month);
    final medals = _ensureMap();
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(monthStart.year, monthStart.month, day);
      if (medals.containsKey(dateOnly(date))) {
        return true;
      }
    }
    return false;
  }

  /// Seeds medals if a given month has no stored data yet.
  /// Uses empty medals so new users start with a clean history.
  void ensureMonthSeed(DateTime month) {
    if (hasAnyForMonth(month)) {
      return;
    }
    seedMedals(_buildEmptyMonth(month));
  }

  /// Seeds medals, preserving existing entries.
  void seedMedals(Map<DateTime, MedalType> medals) {
    final map = _ensureMap();
    medals.forEach((date, medal) {
      final key = dateOnly(date);
      final existing = map[key];
      if (existing == null || existing == MedalType.none) {
        map[key] = medal;
      }
    });
  }

  /// Stores [medal] for [day], overriding previous values.
  void setMedalForDay(DateTime day, MedalType medal) {
    final map = _ensureMap();
    map[dateOnly(day)] = medal;
  }

  /// Provides a safe copy of all stored medals.
  Map<DateTime, MedalType> allMedals() => Map<DateTime, MedalType>.from(_ensureMap());

  /// Returns the total medals stored by type.
  Map<MedalType, int> medalTotals() {
    final totals = <MedalType, int>{
      MedalType.gold: 0,
      MedalType.silver: 0,
      MedalType.bronze: 0,
      MedalType.none: 0,
    };
    for (final medal in _ensureMap().values) {
      totals[medal] = (totals[medal] ?? 0) + 1;
    }
    return totals;
  }

  /// Estimates completed tasks for the given month using medal types.
  List<int> estimatedCompletionsForMonth(int year, int month,
      {int totalTasksPerDay = defaultDailyTaskCount}) {
    ensureMonthSeed(DateTime(year, month));
    final medals = medalsForMonth(DateTime(year, month));
    return medals.entries.map((entry) {
      return _completedTasksFromMedal(entry.value, totalTasksPerDay);
    }).toList();
  }

  Map<DateTime, MedalType> _buildEmptyMonth(DateTime month) {
    final monthStart = DateTime(month.year, month.month);
    final daysInMonth =
        DateUtils.getDaysInMonth(monthStart.year, monthStart.month);
    final map = <DateTime, MedalType>{};

    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(monthStart.year, monthStart.month, day);
      map[date] = MedalType.none;
    }
    return map;
  }

  int _completedTasksFromMedal(MedalType medal, int totalTasks) {
    switch (medal) {
      case MedalType.gold:
        return totalTasks;
      case MedalType.silver:
        return (totalTasks * 0.7).round();
      case MedalType.bronze:
        return (totalTasks * 0.4).round();
      case MedalType.none:
        return 0;
    }
  }
}
