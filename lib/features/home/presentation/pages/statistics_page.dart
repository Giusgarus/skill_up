import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/medal_history_repository.dart';
import '../../data/user_stats_repository.dart';
import '../../domain/calendar_labels.dart';
import '../../domain/medal_utils.dart';
import '../../../auth/data/storage/auth_session_storage.dart';

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key, this.initialYear, this.initialMonth});

  static const route = '/statistics';

  final int? initialYear;
  final int? initialMonth;

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  final UserStatsRepository _statsRepository = UserStatsRepository.instance;
  final AuthSessionStorage _authStorage = AuthSessionStorage();

  late int _selectedYear;
  late int _selectedMonth;
  List<int> _yearOptions = <int>[];
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final session = await _authStorage.readSession();
    if (session != null) {
      MedalHistoryRepository.instance.setActiveUser(session.username);
    }
    final years = _statsRepository.availableYears();
    final fallbackYear = DateTime.now().year;
    final fallbackMonth = DateTime.now().month;
    final selectedYear = widget.initialYear ?? (years.isNotEmpty ? years.last : fallbackYear);
    final selectedMonth = widget.initialMonth ?? fallbackMonth;
    if (!mounted) return;
    setState(() {
      _yearOptions = years.isNotEmpty ? years : <int>[selectedYear];
      _selectedYear = selectedYear;
      _selectedMonth = selectedMonth;
      _initialized = true;
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
    final theme = Theme.of(context);
    final sectionTitle = theme.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
    );
    final cardTextStyle = theme.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    final displayYearOptions =
        _yearOptions.isNotEmpty ? _yearOptions : <int>[_selectedYear];

    final levelInfo = _statsRepository.levelProgress();
    final totals = _statsRepository.medalTotals();
    final yearMedals = _statsRepository.yearTrend(_selectedYear);
    final monthTrend =
        _statsRepository.monthTrend(_selectedYear, _selectedMonth);

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
                  _Header(
                    title: 'STATISTICS',
                    onBackTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(height: 28),
                  _StatsCard(
                    levelInfo: levelInfo,
                    totals: totals,
                    cardTextStyle: cardTextStyle,
                  ),
                  const SizedBox(height: 32),
                  Text('Year', style: sectionTitle),
                  const SizedBox(height: 12),
                  _DropdownPill<int>(
                    value: _selectedYear,
                    items: displayYearOptions,
                    labelBuilder: (value) => value.toString(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedYear = value;
                      });
                    },
                  ),
                  const SizedBox(height: 18),
                  _YearTrendGrid(medals: yearMedals),
                  const SizedBox(height: 32),
                  Text('Month trend', style: sectionTitle),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _DropdownPill<String>(
                          value: 'All tasks',
                          items: const ['All tasks'],
                          labelBuilder: (value) => value,
                          onChanged: (_) {},
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DropdownPill<int>(
                          value: _selectedMonth,
                          items: List<int>.generate(12, (index) => index + 1),
                          labelBuilder: (value) => monthNames[value],
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _selectedMonth = value;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _MonthTrendChart(
                    dataPoints: monthTrend,
                    maxTasks:
                        MedalHistoryRepository.defaultDailyTaskCount.toDouble(),
                  ),
                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onBackTap});

  final String title;
  final VoidCallback onBackTap;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 1.1,
        );
    return Row(
      children: [
        InkWell(
          onTap: onBackTap,
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
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            title,
            style: titleStyle ??
                const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
          ),
        ),
      ],
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.levelInfo,
    required this.totals,
    required this.cardTextStyle,
  });

  final LevelProgress levelInfo;
  final MedalTotals totals;
  final TextStyle? cardTextStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Level: ${levelInfo.level}',
            style: cardTextStyle ??
                const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '(${levelInfo.currentXp}/${levelInfo.xpTarget}xp)',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF444444),
                ),
          ),
          const SizedBox(height: 16),
          Text(
            'Medals: ${totals.gold} ${totals.silver} ${totals.bronze}',
            style: cardTextStyle ??
                const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _medalIcon(MedalType.gold),
              const SizedBox(width: 12),
              _medalIcon(MedalType.silver),
              const SizedBox(width: 12),
              _medalIcon(MedalType.bronze),
            ],
          ),
        ],
      ),
    );
  }

  Widget _medalIcon(MedalType medal) {
    return SizedBox(
      width: 40,
      height: 40,
      child: SvgPicture.asset(
        medalAssetForType(medal),
        colorFilter: medalTintForType(medal) == null
            ? null
            : ColorFilter.mode(medalTintForType(medal)!, BlendMode.srcIn),
      ),
    );
  }
}

class _DropdownPill<T> extends StatelessWidget {
  const _DropdownPill({
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
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
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          icon: const Icon(Icons.arrow_drop_down),
          elevation: 2,
          borderRadius: BorderRadius.circular(20),
          onChanged: onChanged,
          items: items
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item,
                  child: Text(
                    labelBuilder(item),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _YearTrendGrid extends StatelessWidget {
  const _YearTrendGrid({required this.medals});

  final Map<DateTime, MedalType> medals;

  @override
  Widget build(BuildContext context) {
    final sortedDates = medals.keys.toList()..sort();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final date in sortedDates)
            _YearMedalDot(medal: medals[date] ?? MedalType.none),
        ],
      ),
    );
  }
}

class _YearMedalDot extends StatelessWidget {
  const _YearMedalDot({required this.medal});

  final MedalType medal;

  @override
  Widget build(BuildContext context) {
    final color = () {
      switch (medal) {
        case MedalType.gold:
          return const Color(0xFFFFD166);
        case MedalType.silver:
          return const Color(0xFFCED4DA);
        case MedalType.bronze:
          return const Color(0xFFCD7F32);
        case MedalType.none:
          return Colors.black.withValues(alpha: 0.35);
      }
    }();

    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _MonthTrendChart extends StatelessWidget {
  const _MonthTrendChart({
    required this.dataPoints,
    required this.maxTasks,
  });

  final List<int> dataPoints;
  final double maxTasks;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: CustomPaint(
        painter: _LineChartPainter(
          dataPoints: dataPoints,
          maxValue: maxTasks,
        ),
        child: Container(),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.dataPoints,
    required this.maxValue,
  });

  final List<int> dataPoints;
  final double maxValue;

  static const double padding = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final chartWidth = size.width - padding * 2;
    final chartHeight = size.height - padding * 2;
    final origin = Offset(padding, size.height - padding);

    final axisPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;

    // Draw axes
    canvas.drawLine(origin, Offset(origin.dx, origin.dy - chartHeight), axisPaint);
    canvas.drawLine(origin, Offset(origin.dx + chartWidth, origin.dy), axisPaint);

    final labelStyle = const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    final verticalPainter = TextPainter(
      text: TextSpan(text: 'TASKS', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    canvas.translate(origin.dx - 32, origin.dy - chartHeight / 2);
    canvas.rotate(-math.pi / 2);
    verticalPainter.paint(
      canvas,
      Offset(-verticalPainter.width / 2, -verticalPainter.height / 2),
    );
    canvas.restore();

    final horizontalPainter = TextPainter(
      text: TextSpan(text: 'DAYS', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    horizontalPainter.paint(
      canvas,
      Offset(
        origin.dx + chartWidth / 2 - horizontalPainter.width / 2,
        origin.dy + 8,
      ),
    );

    if (dataPoints.isEmpty) {
      return;
    }

    final linePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    final stepX = chartWidth / (dataPoints.length - 1).clamp(1, double.infinity);

    for (var i = 0; i < dataPoints.length; i++) {
      final value = dataPoints[i].clamp(0, maxValue);
      final dx = origin.dx + stepX * i;
      final dy = origin.dy - (value / maxValue) * chartHeight;
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) {
    return oldDelegate.dataPoints != dataPoints ||
        oldDelegate.maxValue != maxValue;
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
