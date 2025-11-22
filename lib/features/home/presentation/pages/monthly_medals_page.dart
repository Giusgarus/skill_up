import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/medal_history_repository.dart';
import '../../domain/calendar_labels.dart';
import '../../domain/medal_utils.dart';
import '../../../auth/data/storage/auth_session_storage.dart';
import 'statistics_page.dart';

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

    // calcolo per la grid
    final firstDayOfMonth =
    DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    final startWeekday = firstDayOfMonth.weekday; // 1 (Mon) - 7 (Sun)
    final totalCells = daysInMonth + (startWeekday - 1);
    final rows = (totalCells / 7).ceil();
    final totalGridItems = rows * 7;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const _GradientBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // top
                  _TopBar(onBack: () => Navigator.of(context).maybePop()),
                  const SizedBox(height: 20),
                  _MonthSelector(
                    monthLabel: monthLabel,
                    onPrevious: () => _changeMonth(-1),
                    onNext: () => _changeMonth(1),
                  ),
                  const SizedBox(height: 20),
                  const _WeekdayHeader(),
                  const SizedBox(height: 8),

                  // 👇 DA QUI IN POI prende tutto lo spazio che resta
                  Expanded(
                    child: GridView.builder(
                      itemCount: totalGridItems,
                      padding: const EdgeInsets.only(top: 4, bottom: 4),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 7,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 8,
                        // più piccolo = cella più alta → ci entrano numero + medaglia grande
                        childAspectRatio: 0.55,
                      ),
                      itemBuilder: (context, index) {
                        // celle vuote prima del 1° e dopo l’ultimo giorno
                        if (index < startWeekday - 1 ||
                            index >= daysInMonth + (startWeekday - 1)) {
                          return const SizedBox.shrink();
                        }

                        final dayNumber = index - (startWeekday - 2);
                        final date = DateTime(
                          _displayedMonth.year,
                          _displayedMonth.month,
                          dayNumber,
                        );
                        final medal = _medals[date] ?? MedalType.none;
                        final isHighlighted =
                            highlightedDay != null && date == highlightedDay;
                        final isToday = date == _today;

                        return _DayCell(
                          date: date,
                          medal: medal,
                          isToday: isToday,
                          isHighlighted: isHighlighted,
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 18),

                  // bottone in fondo
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
    return Transform.translate(
      offset: const Offset(-24, 0), // 👈 togliamo il padding esterno
      child: GestureDetector(
        onTap: onBack,
        child: Container(
          width: 72,
          height: 56,
          decoration: const BoxDecoration(
            color: Color(0xFFB3B3B3),
            borderRadius: BorderRadius.horizontal(
              right: Radius.circular(28), // parte tonda verso il centro
            ),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 14),
          child: Image.asset(
            'assets/icons/back.png',
            width: 30,
            height: 30,
            fit: BoxFit.contain,
          ),
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
    const monthStyle = TextStyle(
      fontFamily: 'FredokaOne',
      fontSize: 44,
      fontWeight: FontWeight.w900,
      fontStyle: FontStyle.italic,
      color: Colors.white,
      letterSpacing: 1.2,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ArrowButton(isLeft: true, onTap: onPrevious),
        const SizedBox(width: 20),
        Text(
          monthLabel,
          style: monthStyle,
        ),
        const SizedBox(width: 20),
        _ArrowButton(isLeft: false, onTap: onNext),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: weekdayShortLabels.map(
            (label) => Expanded(
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'FredokaOne',
                fontSize: 22,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                color: Colors.white,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
      ).toList(),
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
    final String dayLabel = date.day.toString().padLeft(2, '0');

    // se non c’è medaglia → svg vuoto
    final bool hasMedal = medal != MedalType.none;
    final String medalAsset = hasMedal
        ? medalAssetForType(medal)
        : 'assets/icons/blank_star_icon.svg';
    final Color? medalTint = hasMedal ? medalTintForType(medal) : null;

    final bool isTodayOnly = isToday && !isHighlighted;

    final Color borderColor = isHighlighted
        ? Colors.white
        : isTodayOnly
        ? Colors.white.withValues(alpha: 0.6)
        : Colors.transparent;

    final Color bgColor = isHighlighted
        ? Colors.white.withValues(alpha: 0.16)
        : isTodayOnly
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.transparent;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: borderColor,
          width: borderColor == Colors.transparent ? 0 : 2,
        ),
        color: bgColor,
      ),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // numero sopra (come nel mockup)
          Text(
            dayLabel,
            style: const TextStyle(
              fontFamily: 'FredokaOne',
              fontSize: 20,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          // medaglia più grande
          SizedBox(
            width: 40,
            height: 40,
            child: SvgPicture.asset(
              medalAsset,
              fit: BoxFit.contain,
              // coloro solo se è una medaglia vera
              colorFilter: medalTint == null
                  ? null
                  : ColorFilter.mode(medalTint, BlendMode.srcIn),
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
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          height: 60, // 👈 prima era 72
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Go to all statistics',
                style: textStyle ??
                    const TextStyle(
                      fontSize: 16, // 👈 anche un filo più piccolo
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
              ),
              const SizedBox(width: 10),
              SvgPicture.asset(
                'assets/icons/send_icon.svg',
                width: 26,
                height: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({required this.isLeft, required this.onTap});

  final bool isLeft;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _RoundedTrianglePainter(isLeft: isLeft),
        child: const SizedBox(
          width: 18,
          height: 18,
        ),
      ),
    );
  }
}

class _RoundedTrianglePainter extends CustomPainter {
  final bool isLeft;

  _RoundedTrianglePainter({required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final path = Path();

    const double roundness = 3.0; // 👈 maggiore = più curvo

    if (isLeft) {
      path.moveTo(size.width, 0);
      path.quadraticBezierTo(
          size.width - roundness, size.height / 2, size.width, size.height);
      path.lineTo(0, size.height / 2);
    } else {
      path.moveTo(0, 0);
      path.quadraticBezierTo(
          roundness, size.height / 2, 0, size.height);
      path.lineTo(size.width, size.height / 2);
    }

    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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