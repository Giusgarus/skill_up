import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/features/auth/data/services/gathering_api.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/auth/presentation/pages/login_page.dart';
import 'package:skill_up/features/home/data/daily_task_completion_storage.dart';
import 'package:skill_up/features/home/data/medal_history_repository.dart';
import 'package:skill_up/features/home/data/task_api.dart';
import 'package:skill_up/features/home/data/user_stats_repository.dart';
import 'package:skill_up/features/home/domain/calendar_labels.dart';
import 'package:skill_up/features/home/domain/goal_suggestions.dart';
import 'package:skill_up/features/home/domain/medal_utils.dart';
import 'package:skill_up/features/home/presentation/pages/monthly_medals_page.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';
import 'package:skill_up/features/profile/data/user_profile_storage.dart';
import 'package:skill_up/features/profile/presentation/pages/user_info_page.dart';
import 'package:skill_up/features/settings/presentation/pages/settings_page.dart';
import 'package:skill_up/shared/notifications/notification_service.dart';
import 'package:skill_up/features/home/presentation/pages/statistics_page.dart';
import 'plan_overview.dart';
import 'package:skill_up/shared/widgets/gradient_text_field_card.dart';
import 'package:skill_up/shared/widgets/gradient_icon_button.dart';

typedef TaskLongPressCallback = void Function(DailyTask task, Offset position);

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

enum _TaskAction {
  replan,
  reportHarmful,
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
  final GatheringApi _gatheringApi = GatheringApi();
  Timer? _tokenRetryTimer;
  bool _tokenValidationInProgress = false;
  bool _sessionInvalidated = false;
  bool _notificationsRegistered = false;
  bool _profileSyncScheduled = false;
  bool _isFetchingPlan = false;
  String? _planError;
  bool _showHarmfulPrompt = false;
  String? _harmfulPromptMessage;
  static const Duration _tokenRetryDelay = Duration(seconds: 12);
  static const String _serverLogoutMessage =
      'The server has disconnected you. Please log in again to continue.';
  AuthSession? _session;
  int? _activePlanId;
  late final DateTime _today;
  List<DateTime> _currentWeek = const [];
  late DateTime _weekAnchor;
  Map<DateTime, int?> _completedTasksByDay = {};
  final Map<DateTime, List<DailyTask>> _tasksByDay = {};
  final Map<DateTime, Map<String, bool>> _taskStatusesByDay = {};
  List<DailyTask> _tasks = const [];
  late DateTime _selectedDay;
  bool _isAddHabitOpen = false;
  String _newHabitGoal = '';
  ImageProvider? _profileImage;
  bool _isBuildingPlan = false;
  bool _initializedFromRoute = false;
  List<String> _goalSuggestions = buildGoalSuggestions(const []);
  bool _loadingSuggestions = false;

  bool _isFeedbackOpen = false;
  DailyTask? _feedbackTask;
  String _feedbackText = '';

  bool _isReplanOpen = false;
  DailyTask? _replanTask;
  String _replanText = '';

  bool _isReplanningTask = false;

  /// Maximum number of days to check backward for the streak.
  /// You can increase this if you want to consider longer streaks.
  DateTime get _streakLowerBound =>
      dateOnly(_today).subtract(const Duration(days: 365));

  void _showSnack(
      String message, {
        Duration duration = const Duration(milliseconds: 1400),
      }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: duration,
        ),
      );
  }

  @override
  void initState() {
    super.initState();
    _medalRepository = MedalHistoryRepository.instance;
    _today = dateOnly(DateTime.now());
    _currentWeek = _generateWeekFor(_today);
    _weekAnchor = _today;
    _completedTasksByDay = _seedMonthlyCompletedTasks();
    _ensureWeekCoverage();
    _selectedDay = _today;
    unawaited(_loadProfileImage());
    unawaited(_ensureSession().then((_) {
      _loadActivePlan();
      _loadGoalSuggestions();
    }));
    unawaited(_validateSessionWithRetry());
  }


  MedalType _medalForDay(DateTime day) {
    final normalized = dateOnly(day);

    // 1) Se ho i task in memoria per quel giorno, calcolo la medaglia da lì
    final tasks = _tasksByDay[normalized];
    if (tasks != null && tasks.isNotEmpty) {
      final completed = tasks.where((t) => t.isCompleted).length;
      return medalForProgress(
        completed: completed,
        total: tasks.length,
      );
    }

    // 2) Altrimenti, se ho un numero di completati in _completedTasksByDay,
    // lo uso (fallback)
    final storedCompleted = _completedTasksByDay[normalized];
    if (storedCompleted != null) {
      final total = _totalTasksForDay(normalized);
      return medalForProgress(
        completed: storedCompleted,
        total: total,
      );
    }

    // 3) Fallback finale: prova a leggerlo dal MedalHistoryRepository
    //
    try {
      final medal = _medalRepository.medalForDay(normalized);
      return medal ?? MedalType.none;
    } catch (_) {
      // se non hai ancora questo metodo o se qualcosa va storto
      return MedalType.none;
    }
  }

  void _changeWeek(int offsetWeeks) {
    setState(() {
      _weekAnchor = _weekAnchor.add(Duration(days: 7 * offsetWeeks));
      _currentWeek = _generateWeekFor(_weekAnchor);
      _ensureWeekCoverage();

      // Se il giorno selezionato non è nella nuova settimana,
      // lo spostiamo al lunedì della settimana corrente
      if (!_currentWeek.any((d) => dateOnly(d) == _selectedDay)) {
        _selectedDay = _currentWeek.first;
        _tasks = _buildTasksForDay(_selectedDay);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedFromRoute) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is DateTime) {
      final normalized = dateOnly(args);
      _weekAnchor = normalized;
      _currentWeek = _generateWeekFor(_weekAnchor);
      _ensureWeekCoverage();
      _selectedDay = normalized;
      _tasks = _buildTasksForDay(_selectedDay);
    }

    _initializedFromRoute = true;
  }

  @override
  void dispose() {
    _tokenRetryTimer?.cancel();
    _authApi.close();
    _taskApi.close();
    _gatheringApi.close();
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
        _showSnack(_planError!);
      }
    }
  }

  Future<void> _loadGoalSuggestions() async {
    // Evita chiamate duplicate se è già in corso un fetch
    if (_loadingSuggestions) return;

    final session = await _ensureSession();
    if (session == null) {
      return;
    }

    if (mounted) {
      setState(() {
        _loadingSuggestions = true;
      });
    }

    try {
      final result = await _gatheringApi.fetchInterests(token: session.token);
      final suggestions = buildGoalSuggestions(result.interests);

      if (!mounted) return;

      setState(() {
        _goalSuggestions = suggestions;
      });
    } catch (_) {
      // opzionale: puoi mettere una SnackBar qui se vuoi segnalare l'errore
      // se preferisci fallire "silenziosamente", lasciamo vuoto
    } finally {
      if (!mounted) return;
      setState(() {
        _loadingSuggestions = false;
      });
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

  Future<void> _loadProfileImage() async {
    final session = await _ensureSession();
    if (!mounted) return;

    if (session == null) {
      setState(() => _profileImage = null);
      return;
    }

    final file = await _profileStorage.loadProfileImage(session.username);
    if (!mounted) return;

    if (file == null) {
      setState(() => _profileImage = null);
      return;
    }

    final bytes = await file.readAsBytes();
    if (!mounted) return;

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
          title: const Text('Enable the notification'),
          content: const Text(
            'SkillUp sends reminders and updates via notifications. '
            'To continue, press “Continue” and allow notifications in the next window.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
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
      _showSnack(
        'Enable notifications from your system settings to receive updates.',
        duration: const Duration(milliseconds: 4000),
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
        title: const Text('Sessin expired'),
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
    // 0) Se l'utente non ha mai guadagnato alcuna medaglia (tutte none),
    // lo streak è 0.
    final hasAnyMedal = _medalRepository
        .allMedals()
        .values
        .any((m) => m != MedalType.none);

    if (!hasAnyMedal) {
      return 0;
    }

    int streak = 0;
    DateTime day = dateOnly(_today);

    // 1) Se oggi non ha medaglia, proviamo a partire da ieri
    if (_medalRepository.medalForDay(day) == MedalType.none) {
      day = day.subtract(const Duration(days: 1));
    }

    // 2) Andiamo all'indietro finché troviamo giorni con medaglia
    while (!day.isBefore(_streakLowerBound)) {
      final medal = _medalRepository.medalForDay(day);

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
    final toggled = original.copyWith(isCompleted: !original.isCompleted);
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

    unawaited(
      _persistTaskStatus(
        normalizedDay,
        toggled,
        wasCompleted: original.isCompleted,
      ),
    );
  }

  void _selectDay(DateTime date) {
    final normalized = dateOnly(date);
    setState(() {
      _selectedDay = normalized;
      _tasks = _buildTasksForDay(normalized);
    });
  }

  void _openTaskActions(DailyTask task, Offset globalPosition) async {
    final action = await showMenu<_TaskAction>(
      context: context,
      color: Colors.white,
      elevation: 8,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem<_TaskAction>(
          value: _TaskAction.replan,
          child: _TaskMenuItemLabel(
            icon: Icons.edit_outlined,
            label: 'Replan this task',
          ),
        ),
        PopupMenuItem<_TaskAction>(
          value: _TaskAction.reportHarmful,
          child: _TaskMenuItemLabel(
            icon: Icons.flag_outlined,
            label: 'Report harmful response',
            isDestructive: true,
          ),
        ),
      ],
    );

    if (!mounted || action == null) return;

    switch (action) {
      case _TaskAction.replan:
        _openReplanForTask(task);     // 👈 il tuo popup “replan”
        break;
      case _TaskAction.reportHarmful:
        _openFeedbackForTask(task);   // 👈 popup harmful che hai già
        break;
    }
  }

  void _openFeedbackForTask(DailyTask task) {
    setState(() {
      _feedbackTask = task;
      _feedbackText = '';
      _isFeedbackOpen = true;
    });
  }

  void _closeFeedback() {
    setState(() {
      _isFeedbackOpen = false;
      _feedbackTask = null;
      _feedbackText = '';
    });
  }

  void _submitFeedback(String text) {
    final task = _feedbackTask;
    final trimmed = text.trim();
    if (task == null || trimmed.isEmpty) {
      _closeFeedback();
      return;
    }

    _closeFeedback();
    unawaited(_sendFeedback(task, trimmed));
  }

  Future<void> _sendFeedback(DailyTask task, String text) async {
    final session = await _ensureSession();
    if (session == null) {
      _showSnack('No active session found. Please log in again.');
      return;
    }

    try {
      final result = await _taskApi.reportTaskFeedback(
        token: session.token,
        planId: task.planId,
        taskId: task.remoteTaskId,
        report: text,
      );
      if (!mounted) return;
      final message = result.isSuccess
          ? 'Thanks for your feedback 📨'
          : (result.errorMessage ?? 'Unable to send feedback.');
      _showSnack(
        message,
        duration: const Duration(milliseconds: 1500),
      );
    } catch (_) {
  if (!mounted) return;
  _showSnack(
  'Unable to send feedback.',
  duration: const Duration(milliseconds: 1500),
  );
  }
  }



  void _openReplanForTask(DailyTask task) {
    setState(() {
      _replanTask = task;
      _replanText = '';
      _isReplanOpen = true;
    });
  }

  void _closeReplan() {
    setState(() {
      _isReplanOpen = false;
      _replanTask = null;
      _replanText = '';
    });
  }

  void _submitReplan(String text) {
    final task = _replanTask;
    final trimmed = text.trim();

    _closeReplan();

    if (task == null || trimmed.isEmpty) {
      return;
    }

    // 👇 mostra il riquadro con la gif
    setState(() {
      _isReplanningTask = true;
    });

    // per ora simuliamo una chiamata async; poi qui ci metterai la tua API
    unawaited(_simulateReplan(task, trimmed));
  }

  Future<void> _simulateReplan(DailyTask task, String request) async {
    try {
      // TODO: sostituisci con la vera chiamata al backend
      await Future.delayed(const Duration(seconds: 2));

      if (!mounted) return;
      _showSnack(
        'Thanks! We\'ll use this to improve your future tasks 💡',
        duration: const Duration(milliseconds: 1500),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isReplanningTask = false; // 👈 nascondi il riquadro
      });
    }
  }

  Future<void> _persistTaskStatus(
    DateTime day,
    DailyTask task, {
    required bool wasCompleted,
  }) async {
    final session = await _ensureSession();
    if (session == null) {
      return;
    }
    if (task.isCompleted == wasCompleted) {
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
      final result = task.isCompleted
          ? await _taskApi.markTaskDone(
              token: session.token,
              planId: task.planId,
              taskId: task.remoteTaskId,
            )
          : await _taskApi.markTaskUndone(
              token: session.token,
              planId: task.planId,
              taskId: task.remoteTaskId,
            );
      if (!result.isSuccess && mounted) {
        final message =
            result.errorMessage ?? 'Unable to sync task status.';
        _showSnack(
          message,
          duration: const Duration(milliseconds: 1400),
        );
      } else {
        if (task.isCompleted) {
          UserStatsRepository.instance.updateXp(task.score);
        }
        if (result.newScore != null) {
          UserStatsRepository.instance.syncFromScore(result.newScore!);
        }
      }
    } catch (_) {
      if (!mounted) return;
      _showSnack(
        'Unable to sync task status.',
        duration: const Duration(milliseconds: 1400),
      );
    }
  }

  Future<void> _createPlan(String goal) async {
    final session = await _ensureSession();
    if (session == null) {
      _showSnack('No active session found. Please log in again.');
      return;
    }
    setState(() {
      _isBuildingPlan = true;
      _planError = null;
      _showHarmfulPrompt = false;
      _harmfulPromptMessage = null;
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
    final creationRejected = _isRejectedPlan(creationResult);
    final planToShow = creationRejected ? null : _pickBestPlan(creationResult, freshest);

    if (!mounted) return;
    setState(() {
      _isBuildingPlan = false;
    });

    if (creationRejected) {
      final message = _resolveHarmfulPromptMessage(creationResult);
      setState(() {
        _harmfulPromptMessage = message;
        _showHarmfulPrompt = true;
      });
      return;
    }

    final hasPlan =
        planToShow != null && planToShow.isSuccess && planToShow.planId != null;
    final hasTasks = hasPlan && planToShow!.tasks.isNotEmpty;

    if (hasPlan && hasTasks) {
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
        _showSnack('Plan discarded.');
        return;
      }

      // Refresh with all active plans/tasks after accepting
      await _loadActivePlan();
      _showSnack('Plan created successfully.');
    } else {
      if (hasPlan && !hasTasks) {
        unawaited(
          _taskApi.deletePlan(
            token: session.token,
            planId: planToShow!.planId!,
          ),
        );
      }
      final message = hasPlan && !hasTasks
          ? 'The AI did not return any tasks. Please try again.'
          : creationResult?.errorMessage ??
          freshest.errorMessage ??
          'Unable to build the plan right now.';
      _showSnack(message);
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

  bool _isRejectedPlan(PlanResult? result) {
    if (result == null) return false;
    final message = result.errorMessage?.toLowerCase() ?? '';
    if (result.statusCode == 502) return true;
    return message.contains('harmful') ||
        message.contains('not permitted') ||
        message.contains('bad gateway') ||
        message.contains('quest invalid') ||
        message.contains('rejected');
  }

  String _resolveHarmfulPromptMessage(PlanResult? result) {
    return result?.errorMessage?.trim().isNotEmpty == true
        ? result!.errorMessage!
        : 'Oops, your request was flagged as harmful or not permitted.';
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
              300,
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
                _HabitGrid(
                  tasks: _tasks,
                  onTaskTap: _toggleTask,
                  onTaskLongPress: _openTaskActions,
                ),
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
                    onPreviousWeek: () => _changeWeek(-1),
                    onNextWeek: () => _changeWeek(1),
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
                unawaited(_loadGoalSuggestions());
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
                _createPlan(preset);
              },
              onClose: () {
                FocusScope.of(context).unfocus();
                setState(() {
                  _isAddHabitOpen = false;
                  _newHabitGoal = '';
                });
              },
              suggestions: _goalSuggestions,
              loadingSuggestions: _loadingSuggestions,
            ),

          // 6-bis) overlay feedback harmful response
          if (_isFeedbackOpen && _feedbackTask != null)
            _TaskFeedbackOverlay(
              task: _feedbackTask!,
              initialText: _feedbackText,
              onChanged: (value) {
                setState(() => _feedbackText = value);
              },
              onClose: _closeFeedback,
              onSubmit: _submitFeedback,
            ),

          // 6-ter) overlay replan task
          if (_isReplanOpen && _replanTask != null)
            _TaskReplanOverlay(
              task: _replanTask!,
              initialText: _replanText,
              onChanged: (value) {
                setState(() => _replanText = value);
              },
              onClose: _closeReplan,
              onSubmit: _submitReplan,
            ),

          // 7) overlay di loading AI
          if (_isBuildingPlan || _isFetchingPlan || _isReplanningTask)
            _BuildingPlanOverlay(
              message: _isReplanningTask
                  ? 'The AI is\nupdating this task...'
                  : 'The AI is\nbuilding your plan...',
            ),

          // 8) harmful prompt banner
          if (_showHarmfulPrompt)
            _HarmfulPromptBanner(
              message: _harmfulPromptMessage ??
                  'Oops, your request was flagged as harmful or not permitted.',
              onClose: () {
                setState(() {
                  _showHarmfulPrompt = false;
                  _harmfulPromptMessage = null;
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
          image: profileImage,
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
          color: const Color(0xFFB3B3B3),
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
        child: _buildInnerIcon(),
      ),
    );
  }

  Widget _buildInnerIcon() {
    // 🔹 Se NON ho immagine profilo → uso l'asset e basta
    if (image == null) {
      return Image.asset(
        asset!,
        width: 40,
        height: 40,
        fit: BoxFit.contain,
      );
    }

    // 🔹 Se ho immagine profilo → metto cerchio + bordino
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85), // ⭐ bordino elegante
          width: 2.3,
        ),
      ),
      child: ClipOval(
        child: Image(
          image: image!,
          fit: BoxFit.cover,
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
    required this.onPreviousWeek,
    required this.onNextWeek,
  });

  final List<DateTime> weekDays;
  final DateTime selectedDay;
  final DateTime today;
  final Map<DateTime, MedalType> medals;
  final ValueChanged<DateTime> onDaySelected;
  final VoidCallback onPreviousWeek;
  final VoidCallback onNextWeek;

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
        // 🔹 Riga superiore: frecce + giorni della settimana allargati
        Row(
          children: [
            GestureDetector(
              onTap: onPreviousWeek,
              child: const Icon(
                Icons.chevron_left,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Row(
                children: [
                  for (final dayLabel in weekdayShortLabels)
                    Expanded(
                      child: Center(
                        child: Text(dayLabel, style: labelStyle),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: onNextWeek,
              child: const Icon(
                Icons.chevron_right,
                color: Colors.white,
                size: 26,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // 🔹 Riga sotto: SOLO numeri + medaglie, non toccata dalle frecce
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
    // 👉 colore del numero:
    // - se selezionato: bianco (anche se è oggi)
    // - altrimenti, se è oggi: giallino
    // - altrimenti: bianco
    final Color dayTextColor = isSelected
        ? Colors.white
        : (isToday ? const Color(0xFFFFD89B) : Colors.white);

    // stile numero giorno
    final TextStyle textStyle = TextStyle(
      fontFamily: 'FredokaOne',
      fontSize: 26,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
      color: dayTextColor,
      letterSpacing: 1.0,
    );

    final bool hasMedal = medal != MedalType.none;
    final Color? starTint = hasMedal ? medalTintForType(medal) : null;

    // 👉 ora il rettangolino (alone) vale SOLO per il selezionato
    final Color borderColor = isSelected ? Colors.white : Colors.transparent;
    final Color bgColor = isSelected
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.transparent;

    return GestureDetector(
      onTap: () => onTap(date),
      child: Container(
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                // Bordo nero
                Text(
                  '${date.day}',
                  style: textStyle.copyWith(
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 1.3
                      ..color = Colors.black,
                  ),
                ),
                // Riempimento
                Text(
                  '${date.day}',
                  style: textStyle,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (hasMedal)
              SvgPicture.asset(
                medalAssetForType(medal),
                width: 35,
                height: 35,
                colorFilter: starTint != null
                    ? ColorFilter.mode(starTint, BlendMode.srcIn)
                    : null,
              )
            else
              SvgPicture.asset(
                'assets/icons/blank_star_icon.svg',
                width: 35,
                height: 35,
                fit: BoxFit.contain,
              ),
          ],
        ),
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
      height: 26,
      // 🔹 Niente width fissa qui: ci pensa il parent
      child: LayoutBuilder(
        builder: (context, constraints) {
          final barWidth = constraints.maxWidth;

          return ClipRRect(
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
                  // 👇 invece di 120, usiamo la larghezza reale della barra
                  right: isActive ? 0 : barWidth,
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
          );
        },
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
  const _HabitGrid({
    required this.tasks,
    required this.onTaskTap,
    required this.onTaskLongPress,
  });

  final List<DailyTask> tasks;
  final ValueChanged<String> onTaskTap;
  final TaskLongPressCallback onTaskLongPress;

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
              height: itemWidth,
              child: _HabitCard(
                task: task,
                onTap: onTaskTap,
                onLongPress: onTaskLongPress,
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _HabitCard extends StatelessWidget {
  const _HabitCard({
    required this.task,
    required this.onTap,
    this.onLongPress,
  });

  final DailyTask task;
  final ValueChanged<String> onTap;
  final TaskLongPressCallback? onLongPress;

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            task.title,
            style: const TextStyle(
              fontFamily: 'FiraCode',
              fontWeight: FontWeight.w600,
            ),
          ),
          content: SingleChildScrollView(
            child: Text(
              task.description.replaceAll('\n', ' '),
              style: const TextStyle(
                fontFamily: 'FiraCode',
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

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
      onLongPressStart: (details) {
        onLongPress?.call(task, details.globalPosition);
      },
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
        child: Column(
          children: [
            const SizedBox(height: 8),

            // 🔵 rettangolino titolo (identico a prima)
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

            // 🔵 spazio testo — identico a prima
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

            // 🔵 icona expand in basso a destra (NUOVA)
            Padding(
              padding: const EdgeInsets.only(right: 10, bottom: 10),
              child: Align(
                alignment: Alignment.bottomRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showDetails(context),
                  child: const Icon(
                    Icons.open_in_full,
                    size: 20,
                    color: Colors.black87,
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
    required this.suggestions,
    this.loadingSuggestions = false,
  });

  final VoidCallback onClose;
  final String goalText;
  final ValueChanged<String> onGoalChanged;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onPresetSelected;
  final List<String> suggestions;
  final bool loadingSuggestions;

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
                suggestions: widget.suggestions,
                loadingSuggestions: widget.loadingSuggestions,
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
    required this.suggestions,
    this.loadingSuggestions = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onPresetSelected;
  final List<String> suggestions;
  final bool loadingSuggestions;



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
              hintText: 'Write here the general goal you want to achieve ...',
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
          if (loadingSuggestions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Refreshing with your interests...',
                    style: TextStyle(
                      fontFamily: 'FiraCode',
                      fontSize: 14,
                      color: Colors.black.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              // 2 colonne, uno spazio orizzontale da 12 tra le card
              final double itemWidth = (constraints.maxWidth - 12) / 2;
              final toShow = (suggestions.isNotEmpty
                      ? suggestions
                      : buildGoalSuggestions(const []))
                  .take(4)
                  .toList();

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final label in toShow)
                    SizedBox(
                      width: itemWidth,
                      child: _SuggestionChip(
                        label: label,
                        onTap: () => onPresetSelected(label),
                      ),
                    ),
                ],
              );
            },
          ),

          const SizedBox(height: 28),

          Align(
            alignment: Alignment.center,
            child: GradientIconButton(
              width: 130,
              height: 70,
              iconSize: 45,
              onTap: () {
                final goal = controller.text.trim();
                if (goal.isEmpty) return;
                onSubmit(goal);
              },
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
  const _BuildingPlanOverlay({required this.message});

  final String message;

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
              border: Border.all(
                color: Colors.black.withOpacity(1),
                width: 1.5,
              ),
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
                    message, // 👈 ora usa il testo passato
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

class _HarmfulPromptBanner extends StatelessWidget {
  const _HarmfulPromptBanner({
    required this.message,
    required this.onClose,
  });

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Container(
          color: Colors.black.withOpacity(0.5),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Material(
                borderRadius: BorderRadius.circular(22),
                color: Colors.white,
                elevation: 10,
                shadowColor: Colors.black.withOpacity(0.2),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.error_outline, color: Color(0xFFD7263D), size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Request blocked',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.black,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black87,
                          height: 1.35,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: onClose,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'OK',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class _TaskFeedbackOverlay extends StatefulWidget {
  const _TaskFeedbackOverlay({
    required this.task,
    required this.initialText,
    required this.onChanged,
    required this.onSubmit,
    required this.onClose,
  });

  final DailyTask task;
  final String initialText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClose;

  @override
  State<_TaskFeedbackOverlay> createState() => _TaskFeedbackOverlayState();
}

class _TaskFeedbackOverlayState extends State<_TaskFeedbackOverlay> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    widget.onChanged(_controller.text);
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
              child: Container(
                width: 340,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // titolo
                    const Text(
                      'Report harmful response',
                      style: TextStyle(
                        fontFamily: 'FiraCode',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'FiraCode',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Color(0x99000000),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 🔹 TEXTFIELD con bordino gradient come i suggestion chip
                    GradientTextFieldCard(
                      controller: _controller,
                      hintText: 'Tell us what felt harmful, unsafe or wrong...',
                    ),

                    const SizedBox(height: 10),

                    // quick chips
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _FeedbackChip(
                          label: 'Unsafe/violent',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Unsafe/violent]'.trim();
                          },
                        ),
                        _FeedbackChip(
                          label: 'Offensive',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Offensive]'.trim();
                          },
                        ),
                        _FeedbackChip(
                          label: 'Hallucinated',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Hallucinated]'.trim();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    //send button
                    Align(
                      alignment: Alignment.center,
                      child: GradientIconButton(
                        onTap: () => widget.onSubmit(_controller.text),
                        width: 100,
                        height: 56,
                        iconSize: 32,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackChip extends StatelessWidget {
  const _FeedbackChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: const Color(0xFFE5E5E5),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: 'FiraCode',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
      ),
    );
  }
}


class _TaskMenuItemLabel extends StatelessWidget {
  const _TaskMenuItemLabel({
    required this.icon,
    required this.label,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final Color accentStart = const Color(0xFFFF9A9E);
    final Color accentEnd   = const Color(0xFFFFCF71);

    final Color textColor =
    isDestructive ? Colors.red.shade700 : Colors.black;

    return Row(
      children: [
        // piccolo pallino con gradiente dell’app
        Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Icon(
            icon,
            size: 18,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'FiraCode',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ],
    );
  }
}




class _TaskReplanOverlay extends StatefulWidget {
  const _TaskReplanOverlay({
    required this.task,
    required this.initialText,
    required this.onChanged,
    required this.onSubmit,
    required this.onClose,
  });

  final DailyTask task;
  final String initialText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClose;

  @override
  State<_TaskReplanOverlay> createState() => _TaskReplanOverlayState();
}

class _TaskReplanOverlayState extends State<_TaskReplanOverlay> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    widget.onChanged(_controller.text);
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
              child: Container(
                width: 340,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Replan this task',
                      style: TextStyle(
                        fontFamily: 'FiraCode',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'FiraCode',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: Color(0x99000000),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 🔹 TEXTFIELD con bordino gradient
                    GradientTextFieldCard(
                      controller: _controller,
                      hintText: 'What would you change in this task? (timing, difficulty, content...)',
                    ),

                    const SizedBox(height: 10),

                    // quick chips
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _FeedbackChip(
                          label: 'Too easy',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Too easy]'.trim();
                          },
                        ),
                        _FeedbackChip(
                          label: 'Too hard',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Too hard]'.trim();
                          },
                        ),
                        _FeedbackChip(
                          label: 'Wrong timing',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Wrong timing]'.trim();
                          },
                        ),
                        _FeedbackChip(
                          label: 'Not relevant',
                          onTap: () {
                            _controller.text =
                                '${_controller.text} [Not relevant]'.trim();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // send button
                    Align(
                      alignment: Alignment.center,
                      child: GradientIconButton(
                        onTap: () => widget.onSubmit(_controller.text),
                        width: 100,
                        height: 56,
                        iconSize: 32,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

