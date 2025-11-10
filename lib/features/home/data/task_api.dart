import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

class TaskApi {
  TaskApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _taskDoneUri =>
      Uri.parse(baseUrl).resolve('/services/challenges/task_done');

  Future<TaskApiResult> markTaskDone({
    required String token,
    required String taskId,
  }) async {
    final parsedTaskId = int.tryParse(taskId);
    if (parsedTaskId == null) {
      return const TaskApiResult.error('Invalid task identifier.');
    }
    final payload = jsonEncode({'token': token, 'task_id': parsedTaskId});
    try {
      final response = await _client.post(
        _taskDoneUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        return const TaskApiResult.success();
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

  void close() => _client.close();
}

class TaskApiResult {
  const TaskApiResult.success()
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const TaskApiResult.error(this.errorMessage, {this.error, this.stackTrace});

  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}
