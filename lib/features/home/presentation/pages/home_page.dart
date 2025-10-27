import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum MedalType { none, bronze, silver, gold }

const List<String> _monthNames = [
  '',
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const List<String> _weekdayShortLabels = [
  'Mo',
  'Tu',
  'We',
  'Th',
  'Fr',
  'Sa',
  'Su',
];

DateTime _dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String _medalAssetForType(MedalType type) {
  switch (type) {
    case MedalType.gold:
      return 'assets/icons/gold_star_icon.svg';
    case MedalType.silver:
      return 'assets/icons/silver_star_icon.svg';
    case MedalType.bronze:
      return 'assets/icons/bronze_star_icon.svg';
    case MedalType.none:
      return 'assets/icons/blank_star_icon.svg';
  }
}

Color? _medalTintForType(MedalType type) {
  switch (type) {
    case MedalType.none:
      return Colors.black.withValues(alpha: 0.35);
    default:
      return null;
  }
}

class DailyTask {
  const DailyTask({
    required this.id,
    required this.title,
    required this.description,
    required this.cardColor,
    this.textColor = Colors.black,
    this.isCompleted = false,
  });

  final String id;
  final String title;
  final String description;
  final Color cardColor;
  final Color textColor;
  final bool isCompleted;

  DailyTask copyWith({bool? isCompleted}) {
    return DailyTask(
      id: id,
      title: title,
      description: description,
      cardColor: cardColor,
      textColor: textColor,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}

/// Main application page shown after authentication.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  static const route = '/home';

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final DateTime _today;
  late final List<DateTime> _currentWeek;
  late final Map<DateTime, int?> _completedTasksByDay;
  late List<DailyTask> _tasks;
  late DateTime _selectedDay;
  bool _isAddHabitOpen = false;
  String _newHabitGoal = '';
  final Set<int> _newHabitSelectedDays = <int>{};

  @override
  void initState() {
    super.initState();
    _today = _dateOnly(DateTime.now());
    _tasks = _seedTasks();
    _currentWeek = _generateWeekFor(_today);
    _completedTasksByDay = _seedCompletedTasks(_currentWeek);
    _selectedDay = _today;
  }

  List<DateTime> _generateWeekFor(DateTime anchor) {
    final monday = anchor.subtract(Duration(days: anchor.weekday - 1));
    return List<DateTime>.generate(
      7,
      (index) => _dateOnly(monday.add(Duration(days: index))),
    );
  }

  Map<DateTime, int?> _seedCompletedTasks(List<DateTime> week) {
    final map = <DateTime, int?>{};
    for (final day in week) {
      final normalized = _dateOnly(day);
      if (normalized.isAfter(_today)) {
        map[normalized] = null; // future days are pending
        continue;
      }

      if (normalized == _today) {
        map[normalized] = _completedToday;
        continue;
      }

      final offsetDays = _today.difference(normalized).inDays;
      final completed = (_totalTasks - offsetDays)
          .clamp(0, _totalTasks)
          .toInt();
      map[normalized] = completed;
    }
    return map;
  }

  List<DailyTask> _seedTasks() {
    return const [
      DailyTask(
        id: 'drink-water',
        title: 'DRINK MORE',
        description: 'You have to drink\n2 liters of water today',
        cardColor: Color(0xFFE0E0E0),
      ),
      DailyTask(
        id: 'walking',
        title: 'WALKING',
        description: 'Go outside and\nmake 30 minutes of walking',
        cardColor: Color(0xFF5DE27C),
      ),
      DailyTask(
        id: 'stretching',
        title: 'STRETCHING',
        description: 'Stretch your body\nfor at least 10 minutes',
        cardColor: Color(0xFFF1D16A),
      ),
    ];
  }

  int get _totalTasks => _tasks.length;

  int get _completedToday => _tasks.where((task) => task.isCompleted).length;

  int _completedForDay(DateTime day) {
    final normalized = _dateOnly(day);
    if (normalized == _today) {
      return _completedToday;
    }
    final stored = _completedTasksByDay[normalized];
    return stored ?? 0;
  }

  MedalType _medalForProgress({required int completed, required int total}) {
    if (total <= 0 || completed <= 0) {
      return MedalType.none;
    }

    if (completed >= total) {
      return MedalType.gold;
    }

    final ratio = completed / total;
    if (ratio >= 0.5) {
      return MedalType.silver;
    }

    return MedalType.bronze;
  }

  Map<DateTime, MedalType> _buildWeekMedals() {
    final map = <DateTime, MedalType>{};
    for (final date in _currentWeek) {
      final normalized = _dateOnly(date);
      if (normalized.isAfter(_today)) {
        map[normalized] = MedalType.none;
        continue;
      }
      final completed = _completedForDay(normalized);
      map[normalized] = _medalForProgress(
        completed: completed,
        total: _totalTasks,
      );
    }
    return map;
  }

  double get _completionRatio {
    if (_tasks.isEmpty) {
      return 0;
    }
    final completed = _tasks.where((task) => task.isCompleted).length;
    return completed / _tasks.length;
  }

  int get _completionPercent => (_completionRatio * 100).round();

  String get _motivationMessage {
    if (_tasks.isEmpty) {
      return 'You do not have tasks scheduled yet.';
    }
    if (_completionPercent == 100) {
      return 'Great! All daily tasks are complete for today.';
    }
    if (_completionPercent >= 60) {
      return 'Almost there, finish the remaining tasks to complete your day!';
    }
    return 'You are doing a great job, make sure to complete all tasks of today!';
  }

  void _toggleTask(String id) {
    if (_dateOnly(_selectedDay) != _today) {
      return;
    }
    setState(() {
      _tasks = _tasks
          .map(
            (task) => task.id == id
                ? task.copyWith(isCompleted: !task.isCompleted)
                : task,
          )
          .toList();
      final normalizedDay = _dateOnly(_selectedDay);
      _completedTasksByDay[normalizedDay] = _completedToday;
    });
  }

  void _selectDay(DateTime date) {
    setState(() {
      _selectedDay = _dateOnly(date);
    });
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = _monthNames[_selectedDay.month];
    final todaysCompleted = _completedToday;
    final todaysMedal = _medalForProgress(
      completed: todaysCompleted,
      total: _totalTasks,
    );
    final weeklyMedals = _buildWeekMedals();

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
                    monthLabel: monthLabel,
                    onProfileTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Profile coming soon'),
                          duration: Duration(milliseconds: 900),
                        ),
                      );
                    },
                    onSettingsTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Settings coming soon'),
                          duration: Duration(milliseconds: 900),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                  _CalendarStrip(
                    weekDays: _currentWeek,
                    selectedDay: _selectedDay,
                    today: _today,
                    medals: weeklyMedals,
                    onDaySelected: _selectDay,
                  ),
                  const SizedBox(height: 32),
                  _DailyTasksCard(
                    tasks: _tasks,
                    completionPercent: _completionPercent,
                    medalType: todaysMedal,
                    onToggleTask: _toggleTask,
                  ),
                  const SizedBox(height: 20),
                  _MotivationBanner(message: _motivationMessage),
                  const SizedBox(height: 26),
                  _HabitGrid(tasks: _tasks, onTaskTap: _toggleTask),
                  const SizedBox(height: 26),
                  _AddHabitButton(
                    onPressed: () {
                      setState(() {
                        _isAddHabitOpen = true;
                        _newHabitGoal = '';
                        _newHabitSelectedDays.clear();
                      });
                    },
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          if (_isAddHabitOpen)
            _AddHabitOverlay(
              goalText: _newHabitGoal,
              selectedDays: _newHabitSelectedDays,
              onGoalChanged: (value) {
                setState(() {
                  _newHabitGoal = value;
                });
              },
              onDayToggle: (index) {
                setState(() {
                  if (_newHabitSelectedDays.contains(index)) {
                    _newHabitSelectedDays.remove(index);
                  } else {
                    _newHabitSelectedDays.add(index);
                  }
                });
              },
              onSubmit: () {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _newHabitGoal = '';
                  _newHabitSelectedDays.clear();
                });
              },
              onClose: () {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _newHabitGoal = '';
                  _newHabitSelectedDays.clear();
                });
              },
            ),
        ],
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
        child: Stack(
          children: [
            Align(
              alignment: const Alignment(0, -0.2),
              child: SvgPicture.asset(
                'assets/brand/skillup_whitelogo.svg',
                width: 260,
                colorFilter: ColorFilter.mode(
                  Colors.white.withValues(alpha: 0.18),
                  BlendMode.srcIn,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.monthLabel,
    required this.onSettingsTap,
    required this.onProfileTap,
  });

  final String monthLabel;
  final VoidCallback onSettingsTap;
  final VoidCallback onProfileTap;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.1,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _RoundedIconButton(
          asset: 'assets/icons/profile_icon.png',
          onTap: onProfileTap,
        ),
        Text(monthLabel, style: titleStyle ?? const TextStyle(fontSize: 36)),
        _RoundedIconButton(
          asset: 'assets/icons/settings_icon.png',
          onTap: onSettingsTap,
        ),
      ],
    );
  }
}

class _RoundedIconButton extends StatelessWidget {
  const _RoundedIconButton({required this.asset, required this.onTap});

  final String asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isSvg = asset.toLowerCase().endsWith('.svg');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFFD6D6D6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.6),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: isSvg
              ? SvgPicture.asset(
                  asset,
                  width: 32,
                  height: 32,
                  allowDrawingOutsideViewBox: true,
                )
              : Image.asset(asset, width: 32, height: 32, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _CalendarStrip extends StatelessWidget {
  const _CalendarStrip({
    required this.weekDays,
    required this.selectedDay,
    required this.today,
    required this.medals,
    required this.onDaySelected,
  });

  final List<DateTime> weekDays;
  final DateTime selectedDay;
  final DateTime today;
  final Map<DateTime, MedalType> medals;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      letterSpacing: 1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final dayLabel in _weekdayShortLabels)
              Expanded(
                child: Center(child: Text(dayLabel, style: labelStyle)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (final date in weekDays)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _CalendarDayBadge(
                    date: date,
                    medal: medals[_dateOnly(date)] ?? MedalType.none,
                    isSelected: _dateOnly(date) == _dateOnly(selectedDay),
                    isToday: _dateOnly(date) == _dateOnly(today),
                    onTap: onDaySelected,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _CalendarDayBadge extends StatelessWidget {
  const _CalendarDayBadge({
    required this.date,
    required this.medal,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final MedalType medal;
  final bool isSelected;
  final bool isToday;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
      color: isSelected ? const Color(0xFFFFA726) : Colors.white,
      fontWeight: FontWeight.w700,
    );

    final borderColor = isSelected
        ? const Color(0xFFFFA726)
        : isToday
        ? Colors.white.withValues(alpha: 0.7)
        : null;

    final backgroundColor = isSelected
        ? Colors.white
        : Colors.white.withValues(alpha: 0.2);

    final starTint = _medalTintForType(medal);

    return GestureDetector(
      onTap: () => onTap(date),
      child: Column(
        children: [
          Text('${date.day}', style: textStyle),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: borderColor != null
                  ? Border.all(color: borderColor, width: 3)
                  : null,
            ),
            child: SvgPicture.asset(
              _medalAssetForType(medal),
              width: 26,
              height: 26,
              colorFilter: starTint != null
                  ? ColorFilter.mode(starTint, BlendMode.srcIn)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyTasksCard extends StatelessWidget {
  const _DailyTasksCard({
    required this.tasks,
    required this.completionPercent,
    required this.medalType,
    required this.onToggleTask,
  });

  final List<DailyTask> tasks;
  final int completionPercent;
  final MedalType medalType;
  final ValueChanged<String> onToggleTask;

  @override
  Widget build(BuildContext context) {
    final headingStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w800,
      color: Colors.black,
      letterSpacing: 1.2,
    );
    final starTint = _medalTintForType(medalType);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('DAILY TASKS', style: headingStyle)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < tasks.length; i++) ...[
                      _TaskProgressItem(
                        task: tasks[i],
                        onToggleTask: onToggleTask,
                      ),
                      if (i != tasks.length - 1) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 20),
              _CompletionBadge(
                completionPercent: completionPercent,
                medalType: medalType,
                starTint: starTint,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TaskProgressItem extends StatelessWidget {
  const _TaskProgressItem({required this.task, required this.onToggleTask});

  final DailyTask task;
  final ValueChanged<String> onToggleTask;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onToggleTask(task.id),
      child: Row(
        children: [
          Expanded(child: _ProgressBar(isCompleted: task.isCompleted)),
          const SizedBox(width: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: task.isCompleted
                ? const Icon(
                    Icons.check_circle,
                    key: ValueKey('checked'),
                    color: Color(0xFF2ECC71),
                    size: 24,
                  )
                : const Icon(
                    Icons.radio_button_unchecked,
                    key: ValueKey('unchecked'),
                    color: Color(0xFFBDBDBD),
                    size: 24,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.isCompleted});

  final bool isCompleted;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 8,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black.withValues(alpha: 0.08)),
            AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOut,
              widthFactor: isCompleted ? 1 : 0,
              alignment: Alignment.centerLeft,
              child: Container(color: const Color(0xFF3DD178)),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletionBadge extends StatelessWidget {
  const _CompletionBadge({
    required this.completionPercent,
    required this.medalType,
    this.starTint,
  });

  final int completionPercent;
  final MedalType medalType;
  final Color? starTint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$completionPercent%',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF424242),
            ),
            child: SvgPicture.asset(
              _medalAssetForType(medalType),
              width: 28,
              height: 28,
              colorFilter: starTint != null
                  ? ColorFilter.mode(starTint!, BlendMode.srcIn)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MotivationBanner extends StatelessWidget {
  const _MotivationBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: Colors.black.withValues(alpha: 0.75),
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _HabitGrid extends StatelessWidget {
  const _HabitGrid({required this.tasks, required this.onTaskTap});

  final List<DailyTask> tasks;
  final ValueChanged<String> onTaskTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth > 380;
        final itemWidth = twoColumns
            ? (constraints.maxWidth - 16) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: tasks
              .map(
                (task) => SizedBox(
                  width: itemWidth,
                  child: _HabitCard(task: task, onTap: onTaskTap),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _HabitCard extends StatelessWidget {
  const _HabitCard({required this.task, required this.onTap});

  final DailyTask task;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final isCompleted = task.isCompleted;
    final background = isCompleted
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.55), task.cardColor)
        : task.cardColor;
    final textColor = isCompleted
        ? task.textColor.withValues(alpha: 0.6)
        : task.textColor;

    return GestureDetector(
      onTap: () => onTap(task.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: textColor,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: isCompleted ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              task.description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: textColor.withValues(alpha: isCompleted ? 0.7 : 0.9),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddHabitButton extends StatelessWidget {
  const _AddHabitButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(40),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black,
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 16),
            Text(
              'ADD NEW HABIT',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.black,
                letterSpacing: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddHabitOverlay extends StatefulWidget {
  const _AddHabitOverlay({
    required this.onClose,
    required this.goalText,
    required this.selectedDays,
    required this.onGoalChanged,
    required this.onDayToggle,
    required this.onSubmit,
  });

  final VoidCallback onClose;
  final String goalText;
  final Set<int> selectedDays;
  final ValueChanged<String> onGoalChanged;
  final ValueChanged<int> onDayToggle;
  final VoidCallback onSubmit;

  @override
  State<_AddHabitOverlay> createState() => _AddHabitOverlayState();
}

class _AddHabitOverlayState extends State<_AddHabitOverlay> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.goalText);
    _controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant _AddHabitOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goalText != widget.goalText &&
        _controller.text != widget.goalText) {
      _controller.value = TextEditingValue(
        text: widget.goalText,
        selection: TextSelection.collapsed(offset: widget.goalText.length),
      );
    }
  }

  void _handleTextChanged() {
    if (_controller.text != widget.goalText) {
      widget.onGoalChanged(_controller.text);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: _AddHabitOverlayContent(
                controller: _controller,
                selectedDays: widget.selectedDays,
                onDayToggle: widget.onDayToggle,
                onSubmit: widget.onSubmit,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddHabitOverlayContent extends StatelessWidget {
  const _AddHabitOverlayContent({
    required this.controller,
    required this.selectedDays,
    required this.onDayToggle,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final Set<int> selectedDays;
  final ValueChanged<int> onDayToggle;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(38),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText:
                  'Write here what is the goal that you want to achive ...',
              border: InputBorder.none,
              isCollapsed: false,
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1.5, color: Colors.black.withValues(alpha: 0.1)),
          const SizedBox(height: 18),
          Text(
            'In which days you will be available?',
            style: textTheme.bodyLarge?.copyWith(
              color: Colors.black.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              _weekdayShortLabels.length,
              (index) => _DayChip(
                label: _weekdayShortLabels[index],
                isActive: selectedDays.contains(index),
                onTap: () => onDayToggle(index),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Align(
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: onSubmit,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 34,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: SvgPicture.asset(
                  'assets/icons/send_icon.svg',
                  width: 38,
                  height: 38,
                  colorFilter: const ColorFilter.mode(
                    Colors.white,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label, this.isActive = false, this.onTap});

  final String label;
  final bool isActive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final gradient = isActive
        ? const LinearGradient(colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)])
        : const LinearGradient(colors: [Color(0xFFEEEEEE), Color(0xFFEEEEEE)]);

    final textColor = isActive
        ? Colors.white
        : Colors.black.withValues(alpha: 0.6);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: gradient,
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
