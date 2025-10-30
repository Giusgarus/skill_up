import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/medal_history_repository.dart';
import '../../domain/calendar_labels.dart';
import '../../domain/medal_utils.dart';
import '../../../auth/data/storage/auth_session_storage.dart';
import 'statistics_page.dart';

/// Displays medal progress for the selected month.
class MonthlyMedalsPage extends StatefulWidget {
  MonthlyMedalsPage({super.key, DateTime? initialMonth})
      : initialMonth = initialMonth ?? DateTime.now();

  static const route = '/monthly-medals';

  final DateTime initialMonth;

  @override
  State<MonthlyMedalsPage> createState() => _MonthlyMedalsPageState();
}

class _MonthlyMedalsPageState extends State<MonthlyMedalsPage> {
  static const int _defaultDailyTaskCount =
      MedalHistoryRepository.defaultDailyTaskCount;

  final MedalHistoryRepository _repository = MedalHistoryRepository.instance;
  final AuthSessionStorage _authStorage = AuthSessionStorage();

  late final DateTime _initialDay;
  late DateTime _displayedMonth;
  Map<DateTime, MedalType> _medals = <DateTime, MedalType>{};
  bool _initialized = false;

  DateTime get _today => dateOnly(DateTime.now());

  @override
  void initState() {
    super.initState();
    _initialDay = dateOnly(widget.initialMonth);
    final base = DateTime(_initialDay.year, _initialDay.month);
    _displayedMonth = base;
    _initialize(base);
  }

  Future<void> _initialize(DateTime base) async {
    final session = await _authStorage.readSession();
    if (session != null) {
      _repository.setActiveUser(session.username);
    }
    _primeMonthData(base);
    if (!mounted) return;
    setState(() {
      _medals = _repository.medalsForMonth(base);
      _initialized = true;
    });
  }

  void _primeMonthData(DateTime month) {
    _repository.ensureMonthSeed(
      month,
      totalTasksPerDay: _defaultDailyTaskCount,
    );
  }

  void _changeMonth(int offset) {
    final target =
        DateTime(_displayedMonth.year, _displayedMonth.month + offset);
    final normalized = DateTime(target.year, target.month);
    _primeMonthData(normalized);
    setState(() {
      _displayedMonth = normalized;
      _medals = _repository.medalsForMonth(normalized);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            _GradientBackground(),
            Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }
    final monthLabel = monthNames[_displayedMonth.month];
    final daysInMonth =
        DateUtils.getDaysInMonth(_displayedMonth.year, _displayedMonth.month);
    final highlightedDay = (_initialDay.year == _displayedMonth.year &&
            _initialDay.month == _displayedMonth.month)
        ? _initialDay
        : null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const _GradientBackground(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TopBar(onBack: () => Navigator.of(context).maybePop()),
                  const SizedBox(height: 22),
                  _MonthSelector(
                    monthLabel: monthLabel,
                    onPrevious: () => _changeMonth(-1),
                    onNext: () => _changeMonth(1),
                  ),
                  const SizedBox(height: 22),
                  const _WeekdayHeader(),
                  const SizedBox(height: 12),
                  _MonthlyGrid(
                    month: _displayedMonth,
                    daysInMonth: daysInMonth,
                    medals: _medals,
                    today: _today,
                    highlightedDay: highlightedDay,
                  ),
                  const SizedBox(height: 28),
                  _StatisticsButton(
                    onTap: () {
                      Navigator.of(context).pushNamed(
                        StatisticsPage.route,
                        arguments: {
                          'year': _displayedMonth.year,
                          'month': _displayedMonth.month,
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onBack,
      customBorder: const CircleBorder(),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.2),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.7),
            width: 2,
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: Image.asset(
          'assets/icons/back.png',
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class _MonthSelector extends StatelessWidget {
  const _MonthSelector({
    required this.monthLabel,
    required this.onPrevious,
    required this.onNext,
  });

  final String monthLabel;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 1.1,
        );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _ArrowButton(icon: Icons.chevron_left, onTap: onPrevious),
        Text(
          monthLabel,
          style: textStyle ??
              const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
        ),
        _ArrowButton(icon: Icons.chevron_right, onTap: onNext),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.white,
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: weekdayShortLabels
          .map(
            (label) => Expanded(
              child: Center(
                child: Text(
                  label,
                  style: labelStyle ??
                      const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _MonthlyGrid extends StatelessWidget {
  const _MonthlyGrid({
    required this.month,
    required this.daysInMonth,
    required this.medals,
    required this.today,
    this.highlightedDay,
  });

  final DateTime month;
  final int daysInMonth;
  final Map<DateTime, MedalType> medals;
  final DateTime today;
  final DateTime? highlightedDay;

  @override
  Widget build(BuildContext context) {
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final startWeekday = firstDayOfMonth.weekday; // 1 (Mon) - 7 (Sun)
    final totalCells = daysInMonth + (startWeekday - 1);
    final rows = (totalCells / 7).ceil();
    final children = <Widget>[];

    for (var index = 0; index < rows * 7; index++) {
      if (index < startWeekday - 1 || index >= daysInMonth + (startWeekday - 1)) {
        children.add(const SizedBox.shrink());
        continue;
      }
      final dayNumber = index - (startWeekday - 2);
      final date = DateTime(month.year, month.month, dayNumber);
      final medal = medals[date] ?? MedalType.none;
      final isHighlighted = highlightedDay != null && date == highlightedDay;
      final isToday = date == today;
      children.add(
        _DayCell(
          date: date,
          medal: medal,
          isToday: isToday,
          isHighlighted: isHighlighted,
        ),
      );
    }

    return GridView.count(
      shrinkWrap: true,
      crossAxisCount: 7,
      mainAxisSpacing: 12,
      crossAxisSpacing: 8,
      childAspectRatio: 0.8,
      physics: const NeverScrollableScrollPhysics(),
      children: children,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.medal,
    required this.isToday,
    required this.isHighlighted,
  });

  final DateTime date;
  final MedalType medal;
  final bool isToday;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final dayLabel = date.day.toString().padLeft(2, '0');
    final medalAsset = medalAssetForType(medal);
    final medalTint = medalTintForType(medal);

    final isTodayOnly = isToday && !isHighlighted;
    final borderColor = isHighlighted
        ? Colors.white
        : isTodayOnly
            ? Colors.white.withValues(alpha: 0.6)
            : Colors.transparent;
    final backgroundColor = isHighlighted
        ? Colors.white.withValues(alpha: 0.18)
        : isTodayOnly
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.transparent;
    final borderWidth = isHighlighted || isTodayOnly ? 2.0 : 0.0;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: borderColor,
          width: borderWidth,
        ),
        color: backgroundColor,
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 30,
            height: 30,
            child: SvgPicture.asset(
              medalAsset,
              colorFilter:
                  medalTint == null ? null : ColorFilter.mode(medalTint, BlendMode.srcIn),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            dayLabel,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontSize: 14,
                ) ??
                const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatisticsButton extends StatelessWidget {
  const _StatisticsButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.black,
        );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          height: 72,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.85),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Go to all statistics',
                style: textStyle ??
                    const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
              ),
              const SizedBox(width: 12),
              SvgPicture.asset(
                'assets/icons/send_icon.svg',
                width: 30,
                height: 30,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.2),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.7),
              width: 2,
            ),
          ),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFAD0C4), Color(0xFFFFCF71)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}
