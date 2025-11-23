import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:skill_up/shared/network/backend_config.dart';

/// Client for onboarding-related endpoints (interests and questions).
class GatheringApi {
  GatheringApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _interestsUri =>
      Uri.parse(baseUrl).resolve('/services/gathering/interests');
  Uri get _questionsUri =>
      Uri.parse(baseUrl).resolve('/services/gathering/questions');

  Future<GatheringResult> sendInterests({
    required String token,
    required List<String> interests,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'interests': interests,
    });
    return _post(_interestsUri, payload, 'interests');
  }

  Future<GatheringResult> sendQuestions({
    required String token,
    required List<int> answers,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'answers': answers,
    });
    return _post(_questionsUri, payload, 'answers');
  }

  Future<GatheringResult> _post(
    Uri uri,
    String body,
    String target,
  ) async {
    try {
      final response = await _client.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: body,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const GatheringResult.success();
      }
      String? message;
      if (response.body.isNotEmpty) {
        try {
          final Map<String, dynamic> parsed =
              jsonDecode(response.body) as Map<String, dynamic>;
          message = (parsed['detail'] ?? parsed['error'] ?? parsed['message'])
              as String?;
        } catch (_) {
          // ignore
        }
      }
      return GatheringResult.error(
        message ?? 'Unable to submit $target (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const GatheringResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const GatheringResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return GatheringResult.error(
        'Unexpected error while submitting $target.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void close() => _client.close();
}

class GatheringResult {
  const GatheringResult.success()
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const GatheringResult.error(this.errorMessage, {this.error, this.stackTrace});

  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}
