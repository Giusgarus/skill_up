import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

const Map<String, int> _difficultyLookup = {
  'easy': 1,
  'medium': 3,
  'hard': 5,
};

class RemoteTask {
  const RemoteTask({
    required this.taskId,
    required this.planId,
    required this.title,
    required this.description,
    required this.deadline,
    required this.score,
    required this.difficulty,
    this.completedAt,
    this.deleted = false,
  });

  factory RemoteTask.fromJson(
    Map<String, dynamic> json, {
    DateTime? fallbackDeadline,
    int? fallbackPlanId,
    int? fallbackTaskId,
  }) {
    final deadlineRaw = json['deadline_date'] as String? ??
        json['deadline'] as String? ??
        json['date'] as String?;
    DateTime? deadline;
    deadline = _parseDate(deadlineRaw) ?? fallbackDeadline ?? DateTime.now();

    final completedRaw = json['completed_at'];
    DateTime? completedAt;
    if (completedRaw is String && completedRaw.isNotEmpty) {
      completedAt = _parseDate(completedRaw);
    }
    return RemoteTask(
      taskId: (json['task_id'] as num?)?.toInt() ??
          (fallbackTaskId ?? 0),
      planId: (json['plan_id'] as num?)?.toInt() ??
          (fallbackPlanId ?? 0),
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      deadline: deadline,
      score: (json['score'] as num?)?.toInt() ?? 0,
      difficulty: _difficultyFrom(json['difficulty']),
      completedAt: completedAt,
      deleted: json['deleted'] == true,
    );
  }

  final int taskId;
  final int planId;
  final String title;
  final String description;
  final DateTime deadline;
  final int score;
  final int difficulty;
  final DateTime? completedAt;
  final bool deleted;

  bool get isCompleted => completedAt != null;
  DateTime get deadlineDay => DateTime(deadline.year, deadline.month, deadline.day);

  static int _difficultyFrom(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String && raw.isNotEmpty) {
      return _difficultyLookup[raw.toLowerCase().trim()] ?? 1;
    }
    return 1;
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

class PlanResult {
  const PlanResult.success({
    required this.planId,
    required this.tasks,
    this.createdAt,
    this.expectedCompletion,
    this.prompt,
    this.response,
    this.statusCode,
  }) : errorMessage = null,
       error = null,
       stackTrace = null;

  const PlanResult.error(
    this.errorMessage, {
    this.error,
    this.stackTrace,
    this.statusCode,
  })
    : planId = null,
      tasks = const [],
      createdAt = null,
      expectedCompletion = null,
      prompt = null,
      response = null;

  final int? planId;
  final List<RemoteTask> tasks;
  final DateTime? createdAt;
  final DateTime? expectedCompletion;
  final String? prompt;
  final dynamic response;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;
  final int? statusCode;

  bool get isSuccess => errorMessage == null && planId != null;
}

class RemotePlan {
  const RemotePlan({
    required this.planId,
    required this.tasks,
    this.createdAt,
    this.expectedCompletion,
    this.prompt,
  });

  final int planId;
  final List<RemoteTask> tasks;
  final DateTime? createdAt;
  final DateTime? expectedCompletion;
  final String? prompt;
}

class ActivePlanSummary {
  const ActivePlanSummary({
    required this.planId,
    required this.totalTasks,
    required this.completedTasks,
    this.createdAt,
    this.expectedCompletion,
  });

  final int planId;
  final int totalTasks;
  final int completedTasks;
  final DateTime? createdAt;
  final DateTime? expectedCompletion;

  double get completionRatio =>
      totalTasks == 0 ? 0 : completedTasks / totalTasks;
}

class ActivePlansResult {
  const ActivePlansResult.success(this.plans)
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const ActivePlansResult.error(this.errorMessage, {this.error, this.stackTrace})
    : plans = const [];

  final List<ActivePlanSummary> plans;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}

class ActivePlansDetailedResult {
  const ActivePlansDetailedResult.success(this.plans)
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const ActivePlansDetailedResult.error(this.errorMessage, {this.error, this.stackTrace})
    : plans = const [];

  final List<RemotePlan> plans;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}

class TaskApiResult {
  const TaskApiResult.success({this.newScore})
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const TaskApiResult.error(this.errorMessage, {this.error, this.stackTrace})
    : newScore = null;

  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;
  final int? newScore;

  bool get isSuccess => errorMessage == null;
}

class TaskApi {
  TaskApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _taskDoneUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/task_done');
  Uri get _taskUndoUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/task_undo');
  Uri get _activePlanUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/plan/active');
  Uri get _createPlanUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/prompt');
  Uri get _deletePlanUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/plan/delete');
  Uri _hardPlanUri(String preset) =>
      Uri.parse(baseUrl).resolve('/services/challenges/hard/$preset');
  Uri get _reportUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/report');

  Future<PlanResult> fetchActivePlan({required String token}) async {
    final payload = jsonEncode({'token': token});
    try {
      final response = await _client.post(
        _activePlanUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final plans = (body['plans'] as List?)?.whereType<Map>().toList() ?? const [];
        if (plans.isEmpty) {
          return const PlanResult.error('No active plan found.');
        }

        final List<RemoteTask> allTasks = [];
        DateTime? latestCreated;
        DateTime? expected;
        String? prompt;
        dynamic responsePayload;

        for (final plan in plans) {
          final planId = _toInt(plan['plan_id']);
          final tasksJson =
              plan['tasks_all_info'] ?? plan['tasks'] ?? plan['data'] ?? body['tasks'];
          allTasks.addAll(_parseTasks(tasksJson, planId: planId));
          final createdAt = _parseDate(plan['created_at']);
          if (createdAt != null) {
            latestCreated ??= createdAt;
            if (createdAt.isAfter(latestCreated!)) latestCreated = createdAt;
          }
          final planExpected = _parseDate(plan['expected_complete']);
          if (planExpected != null) {
            expected ??= planExpected;
            if (expected!.isBefore(planExpected)) expected = planExpected;
          }
          prompt ??= plan['prompt'] as String?;
          responsePayload ??= plan['response'];
        }

        final anyPlanId = _toInt(plans.first['plan_id']);
        if (anyPlanId == null) {
          return const PlanResult.error('Missing plan id in response.');
        }

        return PlanResult.success(
          planId: anyPlanId,
          tasks: allTasks,
          createdAt: latestCreated,
          expectedCompletion: expected ?? _maxDeadline(allTasks),
          prompt: prompt,
          response: responsePayload,
          statusCode: response.statusCode,
        );
      }
      String? message;
      if (response.body.isNotEmpty) {
        final body = _decodeBody(response.body);
        message = body['detail'] as String? ?? body['error'] as String?;
      }
      return PlanResult.error(
        message ?? 'No active plan found (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    } on SocketException catch (_) {
      return const PlanResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const PlanResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return PlanResult.error(
        'Unexpected error while loading the plan.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<PlanResult> createPlan({
    required String token,
    required String goal,
  }) async {
    final payload = jsonEncode({'token': token, 'goal': goal});
    try {
      final response = await _client.post(
        _createPlanUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final status = body['status'];
        if (status is bool && status == false) {
          final msg = body['detail'] ?? body['error'] ?? body['message'] ?? body['error_message'];
          return PlanResult.error(
            (msg is String ? msg : null) ?? 'Plan creation was rejected.',
            statusCode: response.statusCode,
          );
        }
        final planId = _toInt(body['plan_id']);
        final tasksRaw =
            body['tasks'] ?? (body['data'] is Map ? (body['data'] as Map)['tasks'] : null);
        final tasks = _parseTasks(tasksRaw, planId: planId);
        final llmError = body['error_message'] as String?;

        // if response is incomplete but the server likely created the plan,
        // fall back to querying active plans to recover the data
        if (planId == null || tasks.isEmpty) {
          if (llmError != null && llmError.trim().isNotEmpty) {
            return PlanResult.error(
              llmError,
              statusCode: response.statusCode,
            );
          }
          final recovered = await fetchActivePlan(token: token);
          if (recovered.isSuccess) {
            return recovered;
          }
          return PlanResult.error(
            llmError ??
                recovered.errorMessage ??
                (planId == null
                    ? 'Missing plan id in response.'
                    : 'No tasks returned for this plan.'),
            statusCode: recovered.statusCode,
          );
        }

        return PlanResult.success(
          planId: planId,
          tasks: tasks,
          expectedCompletion: _maxDeadline(tasks),
          createdAt: DateTime.now(),
          prompt: body['prompt'] as String?,
          response: body['response'],
          statusCode: response.statusCode,
        );
      }
      String? message;
      if (response.body.isNotEmpty) {
        final body = _decodeBody(response.body);
        message = body['detail'] as String? ??
            body['error'] as String? ??
            body['message'] as String? ??
            body['error_message'] as String?;
      }
      return PlanResult.error(
        message ?? 'Failed to create a plan (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    } on SocketException catch (_) {
      return const PlanResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const PlanResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return PlanResult.error(
        'Unexpected error while creating the plan.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<PlanResult> createPresetPlan({
    required String token,
    required String preset,
  }) async {
    final payload = jsonEncode({'token': token});
    try {
      final response = await _client.post(
        _hardPlanUri(preset),
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final planId = _toInt(body['plan_id']);
        final tasks = _parseTasks(body['tasks'], planId: planId);
        if (planId == null) {
          return const PlanResult.error('Missing plan id in response.');
        }
        return PlanResult.success(
          planId: planId,
          tasks: tasks,
          expectedCompletion: _maxDeadline(tasks),
          createdAt: _parseDate(body['created_at']) ?? DateTime.now(),
          prompt: body['prompt'] as String?,
          response: body['response'],
          statusCode: response.statusCode,
        );
      }
      String? message;
      if (response.body.isNotEmpty) {
        final body = _decodeBody(response.body);
        message = body['detail'] as String? ??
            body['error'] as String? ??
            body['message'] as String? ??
            body['error_message'] as String?;
      }
      return PlanResult.error(
        message ?? 'Failed to create preset plan (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    } on SocketException catch (_) {
      return const PlanResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const PlanResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return PlanResult.error(
        'Unexpected error while creating the plan.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<ActivePlansResult> fetchActivePlans({required String token}) async {
    final payload = jsonEncode({'token': token});
    try {
      final response = await _client.post(
        _activePlanUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final plansRaw = (body['plans'] as List?)?.whereType<Map>().toList() ?? const [];
        final plans = plansRaw.map(_mapPlanSummary).whereType<ActivePlanSummary>().toList();
        return ActivePlansResult.success(plans);
      }
      return ActivePlansResult.error(
        'Unable to load plans (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const ActivePlansResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ActivePlansResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ActivePlansResult.error(
        'Unexpected error while loading plans.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<ActivePlansDetailedResult> fetchActivePlansDetailed({required String token}) async {
    final payload = jsonEncode({'token': token});
    try {
      final response = await _client.post(
        _activePlanUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final plansRaw = (body['plans'] as List?)?.whereType<Map>().toList() ?? const [];
        final plans = plansRaw.map(_mapPlanDetailed).whereType<RemotePlan>().toList();
        return ActivePlansDetailedResult.success(plans);
      }
      return ActivePlansDetailedResult.error(
        'Unable to load plans (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const ActivePlansDetailedResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ActivePlansDetailedResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ActivePlansDetailedResult.error(
        'Unexpected error while loading plans.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<TaskApiResult> markTaskDone({
    required String token,
    required int planId,
    required int taskId,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'plan_id': planId,
      'task_id': taskId,
    });
    try {
      final response = await _client.post(
        _taskDoneUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final newScore = (body['score'] as num?)?.toInt();
        return TaskApiResult.success(newScore: newScore);
      }
      return TaskApiResult.error(
        'Failed to sync task (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const TaskApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const TaskApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return TaskApiResult.error(
        'Unexpected error syncing task.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<TaskApiResult> markTaskUndone({
    required String token,
    required int planId,
    required int taskId,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'plan_id': planId,
      'task_id': taskId,
    });
    try {
      final response = await _client.post(
        _taskUndoUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final body = _decodeBody(response.body);
        final newScore = (body['score'] as num?)?.toInt();
        return TaskApiResult.success(newScore: newScore);
      }
      return TaskApiResult.error(
        'Failed to undo task (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const TaskApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const TaskApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return TaskApiResult.error(
        'Unexpected error syncing task.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<TaskApiResult> reportTaskFeedback({
    required String token,
    required int planId,
    required int taskId,
    required String report,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'plan_id': planId,
      'task_id': taskId,
      'report': report,
    });
    try {
      final response = await _client.post(
        _reportUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        return const TaskApiResult.success();
      }
      String? message;
      if (response.body.isNotEmpty) {
        try {
          final Map<String, dynamic> parsed =
              jsonDecode(response.body) as Map<String, dynamic>;
          message =
              (parsed['detail'] ?? parsed['error'] ?? parsed['message']) as String?;
        } catch (_) {
          // ignore malformed body
        }
      }
      return TaskApiResult.error(
        message ?? 'Unable to submit feedback (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const TaskApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const TaskApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return TaskApiResult.error(
        'Unexpected error while sending feedback.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<bool> deletePlan({
    required String token,
    required int planId,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'plan_id': planId,
    });
    try {
      final response = await _client.post(
        _deletePlanUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  List<RemoteTask> _parseTasks(dynamic raw, {int? planId}) {
    final tasks = <RemoteTask>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final payload = Map<String, dynamic>.from(entry.cast<String, dynamic>());
          payload.putIfAbsent('plan_id', () => planId);
          _ensureScore(payload);
          tasks.add(RemoteTask.fromJson(
            payload,
            fallbackPlanId: planId,
          ));
        }
      }
    } else if (raw is Map) {
      var counter = 0;
      raw.forEach((key, value) {
        final deadline = _parseDate(key is String ? key : key?.toString()) ??
            DateTime.now();
        final payload = value is Map
            ? Map<String, dynamic>.from(value.cast<String, dynamic>())
            : <String, dynamic>{'title': value?.toString() ?? ''};
        payload.putIfAbsent('deadline_date', () => deadline.toIso8601String());
        payload.putIfAbsent('task_id', () => counter);
        payload.putIfAbsent('plan_id', () => planId);
        _ensureScore(payload);
        tasks.add(
          RemoteTask.fromJson(
            payload,
            fallbackDeadline: deadline,
            fallbackPlanId: planId,
            fallbackTaskId: counter,
          ),
        );
        counter++;
      });
    }
    tasks.removeWhere((task) => task.deleted);
    tasks.sort((a, b) => a.deadline.compareTo(b.deadline));
    return tasks;
  }

  Map<String, dynamic> _decodeBody(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    return jsonDecode(body) as Map<String, dynamic>;
  }

  DateTime? _parseDate(dynamic value) {
    if (value is DateTime) {
      return value;
    }
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  Map<String, dynamic> _pickLatestPlan(List<Map> plans) {
    plans.sort((a, b) {
      final aDate = _parseDate(a['created_at']);
      final bDate = _parseDate(b['created_at']);
      if (aDate != null && bDate != null) {
        return bDate.compareTo(aDate);
      }
      final aId = _toInt(a['plan_id']) ?? 0;
      final bId = _toInt(b['plan_id']) ?? 0;
      return bId.compareTo(aId);
    });
    return plans.first.cast<String, dynamic>();
  }

  DateTime? _maxDeadline(List<RemoteTask> tasks) {
    if (tasks.isEmpty) return null;
    tasks.sort((a, b) => a.deadline.compareTo(b.deadline));
    return tasks.last.deadline;
  }

  ActivePlanSummary? _mapPlanSummary(Map plan) {
    final planId = _toInt(plan['plan_id']);
    if (planId == null) return null;
    final createdAt = _parseDate(plan['created_at']);
    final expectedComplete = _parseDate(plan['expected_complete']);
    final nTasks = _toInt(plan['n_tasks']) ?? 0;
    final nDone = _toInt(plan['n_tasks_done']) ?? 0;
    return ActivePlanSummary(
      planId: planId,
      totalTasks: nTasks,
      completedTasks: nDone,
      createdAt: createdAt,
      expectedCompletion: expectedComplete,
    );
  }

  RemotePlan? _mapPlanDetailed(Map plan) {
    final planId = _toInt(plan['plan_id']);
    if (planId == null) return null;
    final tasksJson = plan['tasks_all_info'] ?? plan['tasks'];
    final tasks = _parseTasks(tasksJson, planId: planId);
    return RemotePlan(
      planId: planId,
      tasks: tasks,
      createdAt: _parseDate(plan['created_at']),
      expectedCompletion: _parseDate(plan['expected_complete']),
      prompt: plan['prompt'] as String?,
    );
  }

  void _ensureScore(Map<String, dynamic> payload) {
    if (payload.containsKey('score')) return;
    final difficulty = RemoteTask._difficultyFrom(payload['difficulty']);
    payload['score'] = difficulty * 10;
  }

  int? _toInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void close() => _client.close();
}
