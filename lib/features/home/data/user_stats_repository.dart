import 'dart:math';

import '../domain/medal_utils.dart';
import 'medal_history_repository.dart';

class LevelProgress {
  const LevelProgress({
    required this.level,
    required this.currentXp,
    required this.xpTarget,
  });

  final int level;
  final int currentXp;
  final int xpTarget;
}

class MedalTotals {
  const MedalTotals({
    required this.gold,
    required this.silver,
    required this.bronze,
  });

  final int gold;
  final int silver;
  final int bronze;
}

/// Stores user stats and derives aggregates from medal history.
class UserStatsRepository {
  UserStatsRepository._();

  static final UserStatsRepository instance = UserStatsRepository._();

  final MedalHistoryRepository _medalRepository =
      MedalHistoryRepository.instance;

  int _level = 30;
  int _currentXp = 12;
  int _xpTarget = 200;

  LevelProgress levelProgress() => LevelProgress(
        level: _level,
        currentXp: _currentXp,
        xpTarget: _xpTarget,
      );

  MedalTotals medalTotals() {
    final totals = _medalRepository.medalTotals();
    return MedalTotals(
      gold: totals[MedalType.gold] ?? 0,
      silver: totals[MedalType.silver] ?? 0,
      bronze: totals[MedalType.bronze] ?? 0,
    );
  }

  List<int> availableYears() {
    final medals = _medalRepository.allMedals();
    if (medals.isEmpty) {
      final currentYear = DateTime.now().year;
      _medalRepository.ensureMonthSeed(DateTime(currentYear, DateTime.now().month));
      return [currentYear];
    }
    final years = medals.keys.map((date) => date.year).toSet().toList()
      ..sort();
    return years;
  }

  Map<DateTime, MedalType> yearTrend(int year) {
    return _medalRepository.medalsForYear(year);
  }

  List<int> monthTrend(int year, int month) {
    return _medalRepository.estimatedCompletionsForMonth(year, month);
  }

  /// Ensures xp stays within expected bounds and recomputes level if needed.
  void updateXp(int gained) {
    _currentXp += gained;
    while (_currentXp >= _xpTarget) {
      _currentXp -= _xpTarget;
      _level += 1;
      _xpTarget = max(100, (_xpTarget * 1.1).round());
    }
  }
}
