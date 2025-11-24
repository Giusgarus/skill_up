import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/auth/presentation/pages/login_page.dart';
import 'package:skill_up/features/home/data/daily_task_completion_storage.dart';
import 'package:skill_up/features/home/data/medal_history_repository.dart';
import 'package:skill_up/features/home/data/task_api.dart';
import 'package:skill_up/features/home/data/user_stats_repository.dart';
import 'package:skill_up/features/home/domain/calendar_labels.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';
import 'package:skill_up/features/home/presentation/pages/monthly_medals_page.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';
import 'package:skill_up/features/profile/data/user_profile_storage.dart';
import 'package:skill_up/features/profile/presentation/pages/user_info_page.dart';
import 'package:skill_up/features/settings/presentation/pages/settings_page.dart';
import 'package:skill_up/shared/notifications/notification_service.dart';
import 'package:skill_up/features/home/presentation/pages/statistics_page.dart';
import 'plan_overview.dart';

class DailyTask {
  const DailyTask({
    required this.id,
    required this.remoteTaskId,
    required this.title,
    required this.description,
    required this.cardColor,
    required this.planId,
    required this.deadline,
    required this.score,
    this.textColor = Colors.black,
    this.isCompleted = false,
  });

  final String id;
  final int remoteTaskId;
  final String title;
  final String description;
  final int planId;
  final DateTime deadline;
  final int score;
  final Color cardColor;
  final Color textColor;
  final bool isCompleted;

  DailyTask copyWith({bool? isCompleted}) {
    return DailyTask(
      id: id,
      remoteTaskId: remoteTaskId,
      title: title,
      description: description,
      planId: planId,
      deadline: deadline,
      cardColor: cardColor,
      score: score,
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
  bool _isFetchingPlan = false;
  String? _planError;
  static const Duration _tokenRetryDelay = Duration(seconds: 12);
  static const String _serverLogoutMessage =
      'Il server ti ha disconnesso. Effettua di nuovo il login per continuare.';
  AuthSession? _session;
  int? _activePlanId;
  late final DateTime _today;
  late final List<DateTime> _currentWeek;
  Map<DateTime, int?> _completedTasksByDay = {};
  final Map<DateTime, List<DailyTask>> _tasksByDay = {};
  final Map<DateTime, Map<String, bool>> _taskStatusesByDay = {};
  List<DailyTask> _tasks = const [];
  late DateTime _selectedDay;
  bool _isAddHabitOpen = false;
  String _newHabitGoal = '';
  ImageProvider? _profileImage;
  bool _isBuildingPlan = false;

  @override
  void initState() {
    super.initState();
    _medalRepository = MedalHistoryRepository.instance;
    _today = dateOnly(DateTime.now());
    _currentWeek = _generateWeekFor(_today);
    _completedTasksByDay = _seedMonthlyCompletedTasks();
    _ensureWeekCoverage();
    _selectedDay = _today;
    unawaited(_loadProfileImage());
    unawaited(_ensureSession().then((_) => _loadActivePlan()));
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

  Future<void> _loadActivePlan() async {
    final session = await _ensureSession();
    if (session == null) {
      return;
    }
    if (mounted) {
      setState(() {
        _isFetchingPlan = true;
        _planError = null;
      });
    }
    final result = await _taskApi.fetchActivePlan(token: session.token);
    if (!mounted) return;
    setState(() => _isFetchingPlan = false);
    if (result.isSuccess && result.planId != null) {
      _setPlanData(result.tasks, result.planId!);
    } else {
      setState(() {
        _activePlanId = null;
        _planError = result.errorMessage;
        _tasks = const [];
        _tasksByDay.clear();
        _taskStatusesByDay.clear();
        _completedTasksByDay = _seedMonthlyCompletedTasks();
      });
      if (_planError != null &&
          !_planError!.toLowerCase().contains('no active plan')) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(_planError!)),
          );
      }
    }
  }

  void _setPlanData(List<RemoteTask> remoteTasks, int planId) {
    final byDay = <DateTime, List<DailyTask>>{};
    final statusByDay = <DateTime, Map<String, bool>>{};
    final completedByDay = <DateTime, int?>{};

    for (final task in remoteTasks) {
      final day = dateOnly(task.deadline);
      final entry = DailyTask(
        id: '${task.planId}-${task.taskId}',
        remoteTaskId: task.taskId,
        title: task.title,
        description: task.description,
        planId: task.planId,
        deadline: task.deadline,
        cardColor: _colorForDifficulty(task.difficulty),
        score: task.score,
        isCompleted: task.isCompleted,
      );
      byDay.putIfAbsent(day, () => <DailyTask>[]).add(entry);
      final statuses = statusByDay.putIfAbsent(day, () => <String, bool>{});
      statuses[entry.id] = entry.isCompleted;
    }

    byDay.forEach((day, tasks) {
      final completed = tasks.where((t) => t.isCompleted).length;
      completedByDay[day] = completed;
      final medal = medalForProgress(
        completed: completed,
        total: tasks.length,
      );
      _medalRepository.setMedalForDay(day, medal);
    });

    setState(() {
      // if multiple plans are active, mark as generic "has plan"
      _activePlanId = remoteTasks.isNotEmpty ? remoteTasks.first.planId : planId;
      _tasksByDay
        ..clear()
        ..addAll(byDay);
      _taskStatusesByDay
        ..clear()
        ..addAll(statusByDay);
      _completedTasksByDay = {
        ..._seedMonthlyCompletedTasks(),
        ...completedByDay,
      };
      _ensureWeekCoverage();
      _selectedDay = _selectedDay;
      _tasks = _buildTasksForDay(_selectedDay);
      _planError = null;
    });
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
      map[date] = null;
    }
    return map;
  }

  void _ensureWeekCoverage() {
    for (final day in _currentWeek) {
      final normalized = dateOnly(day);
      _completedTasksByDay.putIfAbsent(
        normalized,
        () => null,
      );
    }
  }

  void _seedMedalsFromCompletions() {
    if (_session == null) {
      return;
    }
    _completedTasksByDay.forEach((date, completed) {
      final total = _totalTasksForDay(date);
      final medal = completed == null || total == 0
          ? MedalType.none
          : medalForProgress(completed: completed, total: total);
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
      await _ensureNotificationsRegistered(activeSession);
    }
  }

  Future<void> _ensureNotificationsRegistered(AuthSession session) async {
    if (_notificationsRegistered) {
      return;
    }
    final service = NotificationService.instance;
    final granted = await _maybeRequestNotificationPermission(service);
    if (!granted) {
      return;
    }
    await service.registerSession(session);
    _notificationsRegistered = true;
  }

  Future<bool> _maybeRequestNotificationPermission(
    NotificationService service,
  ) async {
    if (service.permissionsGranted) {
      return true;
    }

    var proceed = true;
    if (_shouldShowNotificationDialog(service)) {
      if (!mounted) {
        return false;
      }
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Abilita le notifiche'),
          content: const Text(
            'SkillUp invia promemoria e aggiornamenti tramite notifiche. '
            'Per continuare, premi “Continua” e consenti le notifiche nella finestra successiva.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continua'),
            ),
          ],
        ),
      );
      proceed = result ?? false;
    }

    if (proceed != true) {
      return false;
    }

    final granted = await service.requestPlatformPermissions();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Abilita le notifiche dalle impostazioni di sistema per ricevere gli aggiornamenti.',
          ),
        ),
      );
    }
    return granted;
  }

  bool _shouldShowNotificationDialog(NotificationService service) {
    return !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.macOS &&
        service.shouldPromptForPermission;
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

  List<DailyTask> _buildTasksForDay(DateTime day) {
    final normalized = dateOnly(day);
    final tasks = _tasksByDay[normalized] ?? const <DailyTask>[];
    final statuses = _taskStatusesByDay[normalized];
    if (statuses == null) {
      return List<DailyTask>.from(tasks);
    }
    return tasks
        .map(
          (task) =>
              task.copyWith(isCompleted: statuses[task.id] ?? task.isCompleted),
        )
        .toList();
  }

  int _totalTasksForDay(DateTime day) {
    final normalized = dateOnly(day);
    return _tasksByDay[normalized]?.length ?? 0;
  }

  Color _colorForDifficulty(int difficulty) {
    if (difficulty >= 5) return const Color(0xFFFF9A9E);
    if (difficulty >= 3) return const Color(0xFFF1D16A);
    return const Color(0xFF9BE7A1);
  }

  String _medalCodeFor(MedalType medal) {
    switch (medal) {
      case MedalType.gold:
        return 'G';
      case MedalType.silver:
        return 'S';
      case MedalType.bronze:
        return 'B';
      case MedalType.none:
        return 'None';
    }
  }

  int get _totalTasks => _tasks.length;

  int get _completedToday => _tasks.where((task) => task.isCompleted).length;

  int _completedForDay(DateTime day) {
    final normalized = dateOnly(day);
    final tasks = _tasksByDay[normalized];
    if (tasks != null) {
      return tasks.where((task) => task.isCompleted).length;
    }
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
        total: _totalTasksForDay(normalized),
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
    DateTime day = dateOnly(_today);

    // 1) Controllo se oggi ha una medaglia
    final completedToday = _completedTasksByDay[day];
    final totalToday = _totalTasksForDay(day);
    final bool hasMedalToday = completedToday != null &&
        medalForProgress(
          completed: completedToday,
          total: totalToday,
        ) != MedalType.none;

    // 2) Se oggi NON ha medaglia, partiamo da ieri
    if (!hasMedalToday) {
      day = day.subtract(const Duration(days: 1));
    }

    // 3) Camminiamo all'indietro finché troviamo giorni con medaglia
    while (true) {
      final completed = _completedTasksByDay[day];
      if (completed == null) {
        break; // fuori range / futuro
      }
      final total = _totalTasksForDay(day);
      if (total == 0) {
        break;
      }

      final medal = medalForProgress(
        completed: completed,
        total: total,
      );

      if (medal == MedalType.none) {
        break; // appena troviamo un giorno "fallito" lo streak si ferma
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
    if (_activePlanId == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Create a plan to start completing tasks.'),
          ),
        );
      return;
    }

    final tasksForDay = _tasksByDay[normalizedDay];
    if (tasksForDay == null) {
      return;
    }
    final idx = tasksForDay.indexWhere((task) => task.id == id);
    if (idx == -1) {
      return;
    }
    final original = tasksForDay[idx];
    if (original.isCompleted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('This task is already completed.'),
            duration: Duration(milliseconds: 1400),
          ),
        );
      return;
    }
    final toggled = original.copyWith(isCompleted: true);
    setState(() {
      final updatedDay = List<DailyTask>.from(tasksForDay);
      updatedDay[idx] = toggled;
      _tasksByDay[normalizedDay] = updatedDay;
      final updatedStatuses =
          Map<String, bool>.from(_taskStatusesByDay[normalizedDay] ?? {});
      updatedStatuses[id] = toggled.isCompleted;
      _taskStatusesByDay[normalizedDay] = updatedStatuses;
      _tasks = _buildTasksForDay(normalizedDay);
      final completedCount =
          updatedDay.where((task) => task.isCompleted).length;
      _completedTasksByDay[normalizedDay] = completedCount;
      final medal = medalForProgress(
        completed: completedCount,
        total: updatedDay.length,
      );
      _medalRepository.setMedalForDay(normalizedDay, medal);
    });

    unawaited(_persistTaskStatus(normalizedDay, toggled));
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
    DailyTask task,
  ) async {
    final session = await _ensureSession();
    if (session == null) {
      return;
    }
    try {
      await _taskCompletionStorage.setTaskStatus(
        day,
        task.id,
        task.isCompleted,
        session.username,
      );
    } catch (_) {
      // ignore storage errors silently
    }

    try {
      final result = await _taskApi.markTaskDone(
        token: session.token,
        planId: task.planId,
        taskId: task.remoteTaskId,
      medalTaken: _medalCodeFor(
        medalForProgress(
          completed: _completedForDay(day),
          total: _totalTasksForDay(day),
        ),
      ),
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
      } else {
        // Update XP/level locally based on task score
        UserStatsRepository.instance.updateXp(task.score);
        if (result.newScore != null) {
          UserStatsRepository.instance.syncFromScore(result.newScore!);
        }
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

  Future<void> _createPlan(String goal) async {
    final session = await _ensureSession();
    if (session == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active session found. Please log in again.'),
        ),
      );
      return;
    }
    setState(() {
      _isBuildingPlan = true;
      _planError = null;
    });
    PlanResult? creationResult;
    try {
      creationResult = await _taskApi.createPlan(
        token: session.token,
        goal: goal,
      );
    } catch (_) {
      creationResult = null;
    }

    // Always try to recover the freshest plan from the server
    final freshest = await _waitForPlan(session.token);
    _debugPlanResult('createPlan response', creationResult);
    _debugPlanResult('freshest active plan', freshest);
    final planToShow = _pickBestPlan(creationResult, freshest);

    if (!mounted) return;
    setState(() {
      _isBuildingPlan = false;
    });

    if (planToShow != null && planToShow.isSuccess && planToShow.planId != null) {
      _setPlanData(planToShow.tasks, planToShow.planId!);
      final args = PlanOverviewArgs(
        planId: planToShow.planId!,
        token: session.token,
        tasks: planToShow.tasks,
        prompt: planToShow.prompt ?? goal,
      );
      final decision = await Navigator.of(context).push<PlanDecision>(
        MaterialPageRoute(
          settings: const RouteSettings(name: PlanOverviewPage.route),
          builder: (_) => PlanOverviewPage(args: args),
        ),
      );
      if (!mounted) return;
      if (decision == PlanDecision.declined) {
        await _loadActivePlan();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Plan discarded.')),
        );
        return;
      }

      // Refresh with all active plans/tasks after accepting
      await _loadActivePlan();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Plan created successfully.')),
        );
    } else {
      final message = creationResult?.errorMessage ??
          freshest.errorMessage ??
          'Unable to build the plan right now.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _createPresetPlan(String presetKey) async {
    final session = await _ensureSession();
    if (session == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active session found. Please log in again.'),
        ),
      );
      return;
    }
    setState(() {
      _isBuildingPlan = true;
      _planError = null;
    });
    PlanResult? creationResult;
    try {
      creationResult = await _taskApi.createPresetPlan(
        token: session.token,
        preset: presetKey,
      );
    } catch (_) {
      creationResult = null;
    }

    final freshest = await _waitForPlan(session.token);
    final planToShow = _pickBestPlan(creationResult, freshest);

    if (!mounted) return;
    setState(() {
      _isBuildingPlan = false;
    });

    if (planToShow != null && planToShow.isSuccess && planToShow.planId != null) {
      _setPlanData(planToShow.tasks, planToShow.planId!);
      final args = PlanOverviewArgs(
        planId: planToShow.planId!,
        token: session.token,
        tasks: planToShow.tasks,
        prompt: planToShow.prompt ?? presetKey,
      );
      final decision = await Navigator.of(context).push<PlanDecision>(
        MaterialPageRoute(
          settings: const RouteSettings(name: PlanOverviewPage.route),
          builder: (_) => PlanOverviewPage(args: args),
        ),
      );
      if (!mounted) return;
      if (decision == PlanDecision.declined) {
        await _taskApi.deletePlan(token: session.token, planId: planToShow.planId!);
        await _loadActivePlan();
        return;
      }
      await _loadActivePlan();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Plan created successfully.')),
        );
    } else {
      final message = creationResult?.errorMessage ??
          freshest.errorMessage ??
          'Unable to build the plan right now.';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<PlanResult> _waitForPlan(String token, {int attempts = 6}) async {
    PlanResult last = const PlanResult.error('No plan yet');
    for (var i = 0; i < attempts; i++) {
      last = await _taskApi.fetchActivePlan(token: token);
      if (last.isSuccess && last.planId != null) {
        return last;
      }
      await Future.delayed(const Duration(milliseconds: 650));
    }
    return last;
  }

  PlanResult? _pickBestPlan(PlanResult? primary, PlanResult? secondary) {
    bool valid(PlanResult? p) =>
        p != null && p.isSuccess && p.planId != null;
    if (valid(primary)) return primary;
    if (valid(secondary)) return secondary;
    return primary ?? secondary;
  }

  void _debugPlanResult(String label, PlanResult? result) {
    if (kDebugMode) {
      debugPrint(
        '$label -> '
        'isSuccess=${result?.isSuccess}, '
        'planId=${result?.planId}, '
        'tasks=${result?.tasks.length ?? 0}, '
        'error=${result?.errorMessage}',
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
              300, // 👈 deve essere >= height dello sfondo colorato
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
              height: 280, // 👈 un po’ più lungo per coprire il summary
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFFF9A9E),
                    Color(0xFFF2BEB7),
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

                const SizedBox(height: 10),

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
                });
              },
            ),
          ),

          // 6) overlay sopra tutto
          if (_isAddHabitOpen)
            _AddHabitOverlay(
              goalText: _newHabitGoal,
              onGoalChanged: (value) {
                setState(() {
                  _newHabitGoal = value;
                });
              },
              onSubmit: (goal) {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _isBuildingPlan = true;      // 👉 mostra overlay loading
                });
                _createPlan(goal);             // 👉 chiamata async
              },
              onPresetSelected: (preset) {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _isBuildingPlan = true;
                });
                _createPresetPlan(preset);
              },
              onClose: () {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _newHabitGoal = '';
                });
              },
            ),

          // 7) overlay di loading AI
          if (_isBuildingPlan || _isFetchingPlan)
            const _BuildingPlanOverlay(),
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
    final titleStyle = const TextStyle(
      fontFamily: 'FredokaOne',
      fontSize: 44,
      fontWeight: FontWeight.w900,
      fontStyle: FontStyle.italic, // se vuoi la leggera inclinazione
      color: Colors.white,
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
                  style: titleStyle,
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
    const TextStyle labelStyle = TextStyle(
      fontFamily: 'FredokaOne',   // stesso font del mese
      fontSize: 22,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
      color: Colors.white,
      letterSpacing: 1.0,
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
        const SizedBox(height: 8),
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
    final TextStyle textStyle = TextStyle(
      fontFamily: 'FredokaOne',        // stesso font
      fontSize: 26,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
      color: isSelected ? const Color(0xFFFFA726) : Colors.white,
      letterSpacing: 1.0,
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
    // quante barrette devono essere accese (0–4) in base
    // a percentuale + medaglia
    final int filledLevels = barsForProgress(
      completionPercent: completionPercent,
      medalType: medalType,
    );

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
              style: TextStyle(
                fontFamily: 'FredokaOne',
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: Colors.black,
                fontStyle: FontStyle.italic,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 10),
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
                    style: const TextStyle(
                      fontFamily: 'FredokaOne',
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 6),
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

int barsForProgress({
  required int completionPercent,
  required MedalType medalType,
}) {
  // Nessun task completato → nessuna barra
  if (completionPercent <= 0) {
    return 0;
  }

  // Almeno 1 task → si accende SEMPRE la prima barra
  int bars = 1;

  switch (medalType) {
    case MedalType.none:
    // teoricamente non ci arrivi mai se completionPercent > 0,
    // ma teniamolo per sicurezza
      return bars;

    case MedalType.bronze:
      return 2; // prima + una per bronzo

    case MedalType.silver:
      return 3; // prima + due per argento

    case MedalType.gold:
      return 4; // tutte e 4 accese

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
            style: TextStyle(
              fontFamily: 'FugazOne',
              fontSize: 25,
              fontWeight: FontWeight.w900,
              color: Colors.black,
              fontStyle: FontStyle.italic,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 3),
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
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 26),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(50),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.20),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/icons/+.png',
              width: 28,
              height: 28,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 18),
            Text(
              'ADD NEW GOAL',
              style: TextStyle(
                fontFamily: 'FugazOne',
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: Colors.black,
                fontStyle: FontStyle.italic,
                letterSpacing: 1.2,
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
    required this.onGoalChanged,
    required this.onSubmit,
    required this.onPresetSelected,
  });

  final VoidCallback onClose;
  final String goalText;
  final ValueChanged<String> onGoalChanged;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onPresetSelected;

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
              onTap: () {}, // blocca il tap sul contenuto
              child: _AddHabitOverlayContent(
                controller: _controller,
                onSubmit: (goal) => widget.onSubmit(goal),
                onPresetSelected: widget.onPresetSelected,
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
    required this.onSubmit,
    required this.onPresetSelected,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onPresetSelected;

  void _applySuggestion(String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleSuggestionTap(String text) {
    _applySuggestion(text);
    onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {

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
          // Testo in alto
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Write here the general goal that you want to achive ...',
              border: InputBorder.none,
              isCollapsed: false,
              hintStyle: TextStyle(
                fontFamily: 'FiraCode',   // 👈 stesso font del testo
                fontSize: 18,
                fontWeight: FontWeight.w400,
                height: 1.35,
                letterSpacing: 0.2,
                color: Color(0x99000000), // nero al 60% circa
              ),
            ),
            style: const TextStyle(
              fontFamily: 'FiraCode',     // 👈 Fira Code “pulito”
              fontSize: 18,
              fontWeight: FontWeight.w400,
              height: 1.35,               // spaziatura fra le righe come nello screenshot
              letterSpacing: 0.2,         // leggerissimo tracking da monospace
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Container(height: 1.5, color: Colors.black.withValues(alpha: 0.1)),
          const SizedBox(height: 18),

          // Titolo suggerimenti
          Text(
            'Goal suggestions based on your interests:',
            style: const TextStyle(
              fontFamily: 'FiraCode',     // 👈 Fira Code “pulito”
              fontSize: 18,
              fontWeight: FontWeight.w400,
              height: 1.35,               // spaziatura fra le righe come nello screenshot
              letterSpacing: 0.2,         // leggerissimo tracking da monospace
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),

          // ✅ Griglia 2x2 a larghezza fissa
          LayoutBuilder(
            builder: (context, constraints) {
              // 2 colonne, uno spazio orizzontale da 12 tra le card
              final double itemWidth = (constraints.maxWidth - 12) / 2;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: itemWidth,
                    child: _SuggestionChip(
                      label: 'Move more',
                      onTap: () => onPresetSelected('hard1'),
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _SuggestionChip(
                      label: 'Deep focus',
                      onTap: () => onPresetSelected('hard2'),
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _SuggestionChip(
                      label: 'Strength',
                      onTap: () => onPresetSelected('hard3'),
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _SuggestionChip(
                      label: 'Mind & learn',
                      onTap: () => onPresetSelected('hard4'),
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 28),

          // ✅ Bottone con freccia più simile al mock
          Align(
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () {
                final goal = controller.text.trim();
                if (goal.isEmpty) return; // per ora, se vuoto non facciamo niente
                onSubmit(goal);
              },
              child: Container(
                width: 130,
                height: 70,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: SvgPicture.asset(
                  'assets/icons/send_icon.svg',
                  width: 45,
                  height: 45,
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


class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({
    required this.label,
    this.onTap,
  });

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(1.6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
          ),
        ),
        child: SizedBox(
          height: 60, // ✅ stessa altezza per tutti i bottoni
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Center(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.visible,
                softWrap: true,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withValues(alpha: 0.85),
                  height: 1.2,
                  fontSize: 16, // ⭐ consigliato per avere uniformità
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _BuildingPlanOverlay extends StatelessWidget {
  const _BuildingPlanOverlay();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.35),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/icons/loading_response.gif',
                  width: 84,
                  height: 84,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    'The AI is\nbuilding your plan ...',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class _AiPlanPage extends StatelessWidget {
  const _AiPlanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your plan'),
      ),
      body: const Center(
        child: Text('Here we will show the generated plan.'),
      ),
    );
  }
}
