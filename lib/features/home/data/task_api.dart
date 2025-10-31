import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class TaskApi {
  TaskApi({http.Client? client, this.baseUrl = _defaultBaseUrl})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  static const _defaultBaseUrl = 'http://127.0.0.1:8000';

  Uri get _taskDoneUri => Uri.parse(baseUrl).resolve('/task/done');

  Future<TaskApiResult> markTaskDone({
    required String token,
    required String taskId,
  }) async {
    final payload = jsonEncode({'token': token, 'id_task': taskId});
    try {
      final response = await _client.post(
        _taskDoneUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 201) {
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
