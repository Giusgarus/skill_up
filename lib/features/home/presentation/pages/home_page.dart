import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/auth/presentation/pages/login_page.dart';
import 'package:skill_up/features/home/data/daily_task_completion_storage.dart';
import 'package:skill_up/features/home/data/medal_history_repository.dart';
import 'package:skill_up/features/home/data/task_api.dart';
import 'package:skill_up/features/home/domain/calendar_labels.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';
import 'package:skill_up/features/home/presentation/pages/monthly_medals_page.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';
import 'package:skill_up/features/profile/data/user_profile_storage.dart';
import 'package:skill_up/features/profile/presentation/pages/user_info_page.dart';
import 'package:skill_up/features/settings/presentation/pages/settings_page.dart';
import 'package:skill_up/shared/notifications/notification_service.dart';
import 'package:skill_up/features/home/presentation/pages/statistics_page.dart';

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
  late final MedalHistoryRepository _medalRepository;
  final DailyTaskCompletionStorage _taskCompletionStorage =
      DailyTaskCompletionStorage.instance;
  final UserProfileStorage _profileStorage = UserProfileStorage.instance;
  final AuthSessionStorage _authStorage = AuthSessionStorage();
  final TaskApi _taskApi = TaskApi();
  final AuthApi _authApi = AuthApi();
  Timer? _tokenRetryTimer;
  bool _tokenValidationInProgress = false;
  bool _sessionInvalidated = false;
  bool _notificationsRegistered = false;
  bool _profileSyncScheduled = false;
  static const Duration _tokenRetryDelay = Duration(seconds: 12);
  static const String _serverLogoutMessage =
      'Il server ti ha disconnesso. Effettua di nuovo il login per continuare.';
  AuthSession? _session;
  late final DateTime _today;
  late final List<DateTime> _currentWeek;
  late Map<DateTime, int?> _completedTasksByDay;
  late final List<DailyTask> _taskCatalog;
  final Map<DateTime, Map<String, bool>> _taskStatusesByDay = {};
  late List<DailyTask> _tasks;
  late DateTime _selectedDay;
  bool _isAddHabitOpen = false;
  String _newHabitGoal = '';
  final Set<int> _newHabitSelectedDays = <int>{};
  ImageProvider? _profileImage;

  @override
  void initState() {
    super.initState();
    _medalRepository = MedalHistoryRepository.instance;
    _today = dateOnly(DateTime.now());
    _taskCatalog = _seedTasks();
    _tasks = _buildTasksForDay(_today);
    _currentWeek = _generateWeekFor(_today);
    _completedTasksByDay = _seedMonthlyCompletedTasks();
    _ensureWeekCoverage();
    _seedMedalsFromCompletions();
    _selectedDay = _today;
    unawaited(_loadProfileImage());
    unawaited(_loadPersistedTaskCompletions());
    unawaited(_ensureSession());
    unawaited(_validateSessionWithRetry());
  }

  @override
  void dispose() {
    _tokenRetryTimer?.cancel();
    _authApi.close();
    _taskApi.close();
    super.dispose();
  }

  Future<AuthSession?> _ensureSession() async {
    if (_session != null) {
      return _session;
    }
    _session = await _authStorage.readSession();
    if (_session != null) {
      _medalRepository.setActiveUser(_session!.username);
    }
    return _session;
  }

  List<DateTime> _generateWeekFor(DateTime anchor) {
    final monday = anchor.subtract(Duration(days: anchor.weekday - 1));
    return List<DateTime>.generate(
      7,
      (index) => dateOnly(monday.add(Duration(days: index))),
    );
  }

  Map<DateTime, int?> _seedMonthlyCompletedTasks() {
    final monthStart = DateTime(_today.year, _today.month);
    final daysInMonth = DateUtils.getDaysInMonth(
      monthStart.year,
      monthStart.month,
    );
    final map = <DateTime, int?>{};
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(monthStart.year, monthStart.month, day);
      map[date] = date.isAfter(_today) ? null : 0;
    }
    return map;
  }

  void _ensureWeekCoverage() {
    for (final day in _currentWeek) {
      final normalized = dateOnly(day);
      _completedTasksByDay.putIfAbsent(
        normalized,
        () => normalized.isAfter(_today) ? null : 0,
      );
    }
  }

  void _seedMedalsFromCompletions() {
    if (_session == null) {
      return;
    }
    _completedTasksByDay.forEach((date, completed) {
      final medal = completed == null
          ? MedalType.none
          : medalForProgress(completed: completed, total: _totalTasks);
      _medalRepository.setMedalForDay(date, medal);
    });
  }

  Future<void> _loadPersistedTaskCompletions() async {
    final session = await _ensureSession();
    if (session == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _taskStatusesByDay.clear();
        _tasks = _buildTasksForDay(_selectedDay);
        _completedTasksByDay = _completedTasksByDay.map((date, value) {
          return MapEntry(date, value == null ? null : 0);
        });
        _seedMedalsFromCompletions();
      });
      return;
    }
    final stored = await _taskCompletionStorage.loadMonth(
      _today,
      session.username,
    );
    if (!mounted || stored.isEmpty) {
      return;
    }

    setState(() {
      stored.forEach((date, tasks) {
        final normalized = dateOnly(date);
        final taskMap = Map<String, bool>.from(tasks);
        _taskStatusesByDay[normalized] = taskMap;
        if (!normalized.isAfter(_today)) {
          final completedCount = taskMap.values.where((value) => value).length;
          _completedTasksByDay[normalized] = completedCount;
        }
      });
      _tasks = _buildTasksForDay(_selectedDay);
      _seedMedalsFromCompletions();
    });
  }

  Future<void> _loadProfileImage() async {
    final session = await _ensureSession();
    if (!mounted) {
      return;
    }
    if (session == null) {
      setState(() => _profileImage = null);
      return;
    }
    final file = await _profileStorage.loadProfileImage(session.username);
    if (!mounted) {
      return;
    }
    if (file == null) {
      setState(() => _profileImage = null);
      return;
    }
    final bytes = await file.readAsBytes();
    if (!mounted) {
      return;
    }
    setState(() {
      _profileImage = MemoryImage(bytes);
    });
  }

  Future<void> _validateSessionWithRetry() async {
    if (_sessionInvalidated || _tokenValidationInProgress) {
      return;
    }
    final session = await _ensureSession();
    if (session == null) {
      return;
    }
    _tokenValidationInProgress = true;
    final result = await _authApi.validateToken(
      token: session.token,
      usernameHint: session.username,
    );
    _tokenValidationInProgress = false;
    if (!mounted) {
      return;
    }
    if (result.isValid) {
      await _handleSessionConfirmed(session, result);
      return;
    }
    if (result.isConnectivityIssue) {
      _tokenRetryTimer?.cancel();
      _tokenRetryTimer = Timer(_tokenRetryDelay, () {
        if (!mounted || _sessionInvalidated) {
          return;
        }
        unawaited(_validateSessionWithRetry());
      });
      return;
    }
    await _handleSessionInvalidation(
      message: result.errorMessage ?? _serverLogoutMessage,
    );
  }

  Future<void> _handleSessionConfirmed(
    AuthSession session,
    BearerCheckResult result,
  ) async {
    final normalizedUsername = (result.username?.trim().isNotEmpty ?? false)
        ? result.username!.trim()
        : session.username;
    var activeSession = session;
    if (normalizedUsername != session.username) {
      activeSession = AuthSession(
        token: session.token,
        username: normalizedUsername,
      );
      await _authStorage.saveSession(activeSession);
      _session = activeSession;
      _medalRepository.setActiveUser(activeSession.username);
    }
    if (!_profileSyncScheduled) {
      _profileSyncScheduled = true;
      unawaited(
        UserProfileSyncService.instance.syncAll(
          token: activeSession.token,
          username: activeSession.username,
        ),
      );
    }
    if (!_notificationsRegistered) {
      _notificationsRegistered = true;
      unawaited(NotificationService.instance.registerSession(activeSession));
    }
  }

  Future<void> _handleSessionInvalidation({String? message}) async {
    if (_sessionInvalidated) {
      return;
    }
    _sessionInvalidated = true;
    _tokenRetryTimer?.cancel();
    await _authStorage.clearSession();
    if (!mounted) {
      return;
    }
    await _showServerLogoutDialog(message ?? _serverLogoutMessage);
    if (!mounted) {
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, LoginPage.route, (_) => false);
  }

  Future<void> _showServerLogoutDialog(String message) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Sessione scaduta'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  List<DailyTask> _seedTasks() {
    return const [
      DailyTask(
        id: '1',
        title: 'DRINK MORE',
        description: 'You have to drink\n2 liters of water today',
        cardColor: Color(0xFFE0E0E0),
      ),
      DailyTask(
        id: '2',
        title: 'WALKING',
        description: 'Go outside and\nmake 30 minutes of walking',
        cardColor: Color(0xFF5DE27C),
      ),
      DailyTask(
        id: '3',
        title: 'STRETCHING',
        description: 'Stretch your body\nfor at least 10 minutes',
        cardColor: Color(0xFFF1D16A),
      ),
      DailyTask(
        id: '4',
        title: 'STRETCHING2',
        description: 'Stretch your body\nfor at least 10 minutes',
        cardColor: Color(0xFFF1D16A),
      ),
      DailyTask(
        id: '5',
        title: 'STRETCHING3',
        description: 'Stretch your body\nfor at least 10 minutes',
        cardColor: Color(0xFFF1D16A),
      ),
      DailyTask(
        id: '6',
        title: 'STRETCHING4',
        description: 'Stretch your body\nfor at least 10 minutes',
        cardColor: Color(0xFFF1D16A),
      ),
    ];
  }

  List<DailyTask> _buildTasksForDay(DateTime day) {
    final normalized = dateOnly(day);
    final statuses = _taskStatusesByDay[normalized];
    return _taskCatalog
        .map((task) => task.copyWith(isCompleted: statuses?[task.id] ?? false))
        .toList();
  }

  int get _totalTasks => _taskCatalog.length;

  int get _completedToday => _tasks.where((task) => task.isCompleted).length;

  int _completedForDay(DateTime day) {
    final normalized = dateOnly(day);
    final statuses = _taskStatusesByDay[normalized];
    if (statuses != null) {
      return statuses.values.where((value) => value).length;
    }
    final stored = _completedTasksByDay[normalized];
    return stored ?? 0;
  }

  Map<DateTime, MedalType> _buildWeekMedals() {
    final map = <DateTime, MedalType>{};
    for (final date in _currentWeek) {
      final normalized = dateOnly(date);
      if (normalized.isAfter(_today)) {
        map[normalized] = MedalType.none;
        continue;
      }
      final completed = _completedForDay(normalized);
      map[normalized] = medalForProgress(
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

  int get _currentStreak {
    int streak = 0;
    DateTime day = _today;

    while (true) {
      // se non abbiamo info su quel giorno, o è nel futuro, stop
      final completed = _completedTasksByDay[day];
      if (completed == null) {
        break;
      }

      // calcoliamo la medaglia di quel giorno
      final medal = medalForProgress(completed: completed, total: _totalTasks);

      // se non c'è medaglia (none), lo streak si interrompe
      if (medal == MedalType.none) {
        break;
      }

      streak++;
      day = day.subtract(const Duration(days: 1));
    }

    return streak;
  }

  void _toggleTask(String id) {
    final normalizedDay = dateOnly(_selectedDay);
    if (normalizedDay != _today) {
      return;
    }

    DailyTask? toggledTask;
    setState(() {
      _tasks = _tasks.map((task) {
        if (task.id == id) {
          toggledTask = task.copyWith(isCompleted: !task.isCompleted);
          return toggledTask!;
        }
        return task;
      }).toList();
      final updatedStatuses = Map<String, bool>.from(
        _taskStatusesByDay[normalizedDay] ?? <String, bool>{},
      );
      if (toggledTask != null) {
        updatedStatuses[id] = toggledTask!.isCompleted;
      }
      _taskStatusesByDay[normalizedDay] = updatedStatuses;

      final completedCount = updatedStatuses.values
          .where((value) => value)
          .length;
      _completedTasksByDay[normalizedDay] = completedCount;
      final medal = medalForProgress(
        completed: completedCount,
        total: _totalTasks,
      );
      _medalRepository.setMedalForDay(normalizedDay, medal);
      _seedMedalsFromCompletions();
    });

    final newStatus = toggledTask?.isCompleted ?? false;
    unawaited(_persistTaskStatus(normalizedDay, id, newStatus));
  }

  void _selectDay(DateTime date) {
    final normalized = dateOnly(date);
    setState(() {
      _selectedDay = normalized;
      _tasks = _buildTasksForDay(normalized);
    });
  }

  Future<void> _persistTaskStatus(
    DateTime day,
    String taskId,
    bool isCompleted,
  ) async {
    final session = await _ensureSession();
    if (session == null) {
      return;
    }
    try {
      await _taskCompletionStorage.setTaskStatus(
        day,
        taskId,
        isCompleted,
        session.username,
      );
    } catch (_) {
      // ignore storage errors silently
    }

    try {
      final result = await _taskApi.markTaskDone(
        token: session.token,
        taskId: taskId,
      );
      if (!result.isSuccess && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                result.errorMessage ?? 'Unable to sync task status.',
              ),
              duration: const Duration(milliseconds: 1400),
            ),
          );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Unable to sync task status.'),
            duration: Duration(milliseconds: 1400),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = monthNames[_selectedDay.month];
    final todaysCompleted = _completedToday;
    final todaysMedal = medalForProgress(
      completed: todaysCompleted,
      total: _totalTasks,
    );
    final weeklyMedals = _buildWeekMedals();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 1) sfondo principale
          const _GradientBackground(),

          // 2) CONTENUTO SCORREVOLE (dietro)
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              24,
              280, // 👈 deve essere >= height dello sfondo colorato
              24,
              18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _DailyTasksCard(
                      tasks: _tasks,
                      completionPercent: _completionPercent,
                      medalType: todaysMedal,
                      onToggleTask: _toggleTask,
                      onLongPress: () {
                        Navigator.of(context).pushNamed(
                          StatisticsPage.route,
                          arguments: {
                            'year': _selectedDay.year,
                            'month': _selectedDay.month,
                          },
                        );
                      },
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -12),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _StreakBanner(streakDays: _currentStreak),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _HabitGrid(tasks: _tasks, onTaskTap: _toggleTask),
                const SizedBox(height: 120),
              ],
            ),
          ),

          // 3) SFONDO COLORATO FISSO (solo background, può avere height fissa)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 270, // 👈 un po’ più lungo per coprire il summary
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFFF9A9E),
                    Color(0xFFFAD0C4),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(28),
                  bottomRight: Radius.circular(28),
                ),
              ),
            ),
          ),

          // 4) CONTENUTO FISSO (header + calendario) SENZA height fissa
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 👇 header SENZA padding laterale, così i pill toccano i bordi
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: _Header(
                    monthLabel: monthLabel,
                    onProfileTap: () {
                      Navigator.of(context)
                          .pushNamed(UserInfoPage.route)
                          .then((_) => _loadProfileImage());
                    },
                    onSettingsTap: () {
                      Navigator.of(context).pushNamed(SettingsPage.route);
                    },
                    onMonthTap: () {
                      Navigator.of(context).pushNamed(
                        MonthlyMedalsPage.route,
                        arguments: dateOnly(_selectedDay),
                      );
                    },
                    profileImage: _profileImage,
                  ),
                ),

                const SizedBox(height: 28),

                // 👇 tutto il resto con il padding 24 come prima
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _CalendarStrip(
                    weekDays: _currentWeek,
                    selectedDay: _selectedDay,
                    today: _today,
                    medals: weeklyMedals,
                    onDaySelected: _selectDay,
                  ),
                ),
              ],
            ),
          ),

          // 5) bottone fisso in basso
          Positioned(
            left: 24,
            right: 24,
            bottom: 24,
            child: _AddHabitButton(
              onPressed: () {
                setState(() {
                  _isAddHabitOpen = true;
                  _newHabitGoal = '';
                  _newHabitSelectedDays.clear();
                });
              },
            ),
          ),

          // 6) overlay sopra tutto
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
    required this.onMonthTap,
    this.profileImage,
  });

  final String monthLabel;
  final VoidCallback onSettingsTap;
  final VoidCallback onProfileTap;
  final VoidCallback onMonthTap;
  final ImageProvider? profileImage;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.1,
    );

    return Row(
      children: [
        // sinistra
        _SidePillButton(
          onTap: onProfileTap,
          isLeft: true,
          asset: 'assets/icons/profile_icon.png',
        ),

        // centro flessibile
        Expanded(
          child: Center(
            child: InkWell(
              onTap: onMonthTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  monthLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle ?? const TextStyle(fontSize: 36),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),

        // destra
        _SidePillButton(
          onTap: onSettingsTap,
          isLeft: false,
          asset: 'assets/icons/settings_icon.png',
        ),
      ],
    );
  }
}

class _SidePillButton extends StatelessWidget {
  const _SidePillButton({
    required this.onTap,
    required this.isLeft,
    this.asset,
    this.image,
    this.width = 72,
  }) : assert(asset != null || image != null);

  final VoidCallback onTap;
  final bool isLeft;
  final String? asset;
  final ImageProvider? image;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFFB3B3B3), // ✅ grigio corretto
          borderRadius: BorderRadius.horizontal(
            left: isLeft ? Radius.zero : const Radius.circular(28),
            right: isLeft ? const Radius.circular(28) : Radius.zero,
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
        child: Image.asset(
          asset!,          // ✅ ora carichi sempre il PNG
          width: 40,
          height: 40,
          fit: BoxFit.contain,
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
            for (final dayLabel in weekdayShortLabels)
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
                    medal: medals[dateOnly(date)] ?? MedalType.none,
                    isSelected: dateOnly(date) == dateOnly(selectedDay),
                    isToday: dateOnly(date) == dateOnly(today),
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

    final bool hasMedal = medal != MedalType.none;
    final Color? starTint = hasMedal ? medalTintForType(medal) : null;

    return GestureDetector(
      onTap: () => onTap(date),
      child: Column(
        mainAxisSize: MainAxisSize.min, // 👈 importante
        children: [
          Text('${date.day}', style: textStyle),
          const SizedBox(height: 4), // 👈 prima era 8
          if (hasMedal)
            SvgPicture.asset(
              medalAssetForType(medal),
              width: 35, // 👈 un po' più piccolo
              height: 35,
              colorFilter: starTint != null
                  ? ColorFilter.mode(starTint, BlendMode.srcIn)
                  : null,
            )
          else
            SvgPicture.asset(
              'assets/icons/blank_star_icon.svg',
              width: 35, // 👈 anche il blank uguale
              height: 35,
              fit: BoxFit.contain,
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
    this.onLongPress,
  });

  final List<DailyTask> tasks;
  final int completionPercent;
  final MedalType medalType;
  final ValueChanged<String> onToggleTask;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    // quante “fasce” devono essere accese (25% ciascuna)
    final int filledLevels = completionPercent == 0
        ? 0
        : (completionPercent / 25).ceil();

    final Color? starTint = medalTintForType(medalType);

    // ✅ qui salvi il contenitore in una variabile
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(38),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Text(
              'DAILY TASKS',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.black,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 🔹 Colonna barre
              SizedBox(
                width: 130,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(4, (index) {
                    final reversedIndex = 3 - index;
                    final isActive = reversedIndex < filledLevels;
                    return Padding(
                      padding: EdgeInsets.only(bottom: index == 3 ? 0 : 10),
                      child: _SummaryLevelBar(isActive: isActive),
                    );
                  }),
                ),
              ),
              const SizedBox(width: 30),

              // 🔹 Percentuale + medaglia
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$completionPercent%',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: 78,
                    height: 78,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF3F3F3F),
                    ),
                    alignment: Alignment.center,
                    child: medalType == MedalType.none
                        ? SvgPicture.asset(
                      'assets/icons/blank_star_icon.svg',
                      width: 78,
                      height: 78,
                      fit: BoxFit.contain,
                    )
                        : SizedBox(
                      width: 78,
                      height: 78,
                      child: SvgPicture.asset(
                        medalAssetForType(medalType),
                        fit: BoxFit.contain,
                        colorFilter: starTint != null
                            ? ColorFilter.mode(starTint, BlendMode.srcIn)
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    // ✅ qui ritorni il card wrappato nel GestureDetector
    return GestureDetector(
      onLongPress: onLongPress,
      child: card,
    );
  }
}

class _SummaryLevelBar extends StatelessWidget {
  const _SummaryLevelBar({required this.isActive});

  final bool isActive;

  static const _fillDuration = Duration(milliseconds: 520);
  static const _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 26,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // base grigia
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFD8D8D8),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            // riempimento animato
            AnimatedPositioned(
              duration: _fillDuration,
              curve: _curve,
              left: 0,
              top: 0,
              bottom: 0,
              right: isActive ? 0 : 120,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF3BC259), Color(0xFF63DE77)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            // bagliore bianco per dare l'idea di energia
            IgnorePointer(
              child: AnimatedOpacity(
                duration: _fillDuration,
                curve: _curve,
                opacity: isActive ? 0.25 : 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: 0.35,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.8),
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreakBanner extends StatelessWidget {
  const _StreakBanner({required this.streakDays});

  final int streakDays;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFE5E5E5).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center, // testo + fiamma centrati
        children: [
          Text(
            '$streakDays DAYS STREAK',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.black,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 8),
          Image.asset(
            'assets/icons/fire_streak_icon.png', // 👈 percorso dell’immagine
            width: 60,
            height: 60,
            fit: BoxFit.contain,
          ),
        ],
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
        final itemWidth = (constraints.maxWidth - 16) / 2;

        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: tasks.map((task) {
            return SizedBox(
              width: itemWidth,
              height: itemWidth, // 👈 card quadrata
              child: _HabitCard(task: task, onTap: onTaskTap),
            );
          }).toList(),
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
    final bool isCompleted = task.isCompleted;

    // colori
    final Color inactiveBase = const Color(0xFFD6D6D6);
    final Color activeBase = const Color(0xFF63DE77);
    final Color inactiveTitle = const Color(0xFFB3B3B3);
    final Color activeTitle = const Color(0xFF5CD16A);

    final Color baseColor = isCompleted ? activeBase : inactiveBase;
    final Color titleColor = isCompleted ? activeTitle : inactiveTitle;

    return GestureDetector(
      onTap: () => onTap(task.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 10,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        // importantissimo: riempi e poi gestisci lo spazio dentro
        child: Column(
          children: [
            const SizedBox(height: 8),

            // rettangolino titolo
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
              decoration: BoxDecoration(
                color: titleColor,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Center(
                child: Text(
                  task.title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 1.1,
                    fontSize: 14,
                  ),
                ),
              ),
            ),

            // questo Expanded prende lo spazio che resta e NON fa sforare
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Center(
                  child: Text(
                    task.description.replaceAll('\n', ' '),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),

            // icona in basso SEMPRE visibile
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Image.asset(
                isCompleted
                    ? 'assets/icons/task_done_icon.png'
                    : 'assets/icons/task_not_done_icon.png',
                width: 38,
                height: 38,
                fit: BoxFit.contain,
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
              weekdayShortLabels.length,
              (index) => _DayChip(
                label: weekdayShortLabels[index],
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
