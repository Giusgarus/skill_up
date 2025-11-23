import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

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

  factory RemoteTask.fromJson(Map<String, dynamic> json) {
    final deadlineRaw = json['deadline_date'] as String?;
    DateTime? deadline;
    if (deadlineRaw != null) {
      deadline = DateTime.tryParse(deadlineRaw);
    }
    final completedRaw = json['completed_at'];
    DateTime? completedAt;
    if (completedRaw is String && completedRaw.isNotEmpty) {
      completedAt = DateTime.tryParse(completedRaw);
    }
    return RemoteTask(
      taskId: (json['task_id'] as num?)?.toInt() ?? 0,
      planId: (json['plan_id'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      deadline: deadline ?? DateTime.now(),
      score: (json['score'] as num?)?.toInt() ?? 0,
      difficulty: (json['difficulty'] as num?)?.toInt() ?? 1,
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
}

class PlanResult {
  const PlanResult.success({
    required this.planId,
    required this.tasks,
    this.createdAt,
    this.expectedCompletion,
  }) : errorMessage = null,
       error = null,
       stackTrace = null;

  const PlanResult.error(this.errorMessage, {this.error, this.stackTrace})
    : planId = null,
      tasks = const [],
      createdAt = null,
      expectedCompletion = null;

  final int? planId;
  final List<RemoteTask> tasks;
  final DateTime? createdAt;
  final DateTime? expectedCompletion;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null && planId != null;
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
  Uri get _activePlanUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/plan/active');
  Uri get _createPlanUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/prompt');

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
        final plan = body['plan'] as Map<String, dynamic>? ?? {};
        final planId = (plan['plan_id'] ?? body['plan_id']) as int?;
        final tasksJson = body['tasks'];
        final tasks = _parseTasks(tasksJson);
        if (planId == null) {
          return const PlanResult.error('Missing plan id in response.');
        }
        return PlanResult.success(
          planId: planId,
          tasks: tasks,
          createdAt: _parseDate(plan['created_at']),
          expectedCompletion: _parseDate(plan['expected_complete']),
        );
      }
      return PlanResult.error('No active plan found (${response.statusCode}).');
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
        final planId = (body['plan_id'] as num?)?.toInt();
        final tasks = _parseTasks(body['tasks']);
        final data = body['data'] as Map<String, dynamic>? ?? {};
        if (planId == null) {
          return const PlanResult.error('Missing plan id in response.');
        }
        return PlanResult.success(
          planId: planId,
          tasks: tasks,
          expectedCompletion: _parseDate(data['expected_complete']),
        );
      }
      return PlanResult.error(
        'Failed to create a plan (${response.statusCode}).',
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

  Future<TaskApiResult> markTaskDone({
    required String token,
    required int planId,
    required int taskId,
    String medalTaken = 'None',
  }) async {
    final payload = jsonEncode({
      'token': token,
      'plan_id': planId,
      'task_id': taskId,
      'medal_taken': medalTaken,
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

  List<RemoteTask> _parseTasks(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => RemoteTask.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  Map<String, dynamic> _decodeBody(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    return jsonDecode(body) as Map<String, dynamic>;
  }

  DateTime? _parseDate(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  void close() => _client.close();
}
