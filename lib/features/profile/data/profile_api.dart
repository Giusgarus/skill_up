import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

import 'profile_field_mapping.dart';

class ProfileApi {
  ProfileApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _updateUri => Uri.parse(baseUrl).resolve('/services/challenges/set');

  Future<ProfileApiResult> uploadProfilePicture({
    required String token,
    required String base64Image,
  }) async {
    final sanitized = base64Image.trim();
    if (sanitized.isEmpty) {
      return const ProfileApiResult.error('Missing profile picture data.');
    }
    return _postUpdate(
      token: token,
      attribute: 'profile_pic',
      record: sanitized,
      targetDescription: 'profile picture',
    );
  }

  Future<ProfileApiResult> updateField({
    required String token,
    required String field,
    required String value,
  }) async {
    final trimmed = field.trim();
    if (trimmed.isEmpty) {
      return const ProfileApiResult.error('Missing field name.');
    }
    final attribute = backendAttributeForField(trimmed);
    if (attribute == null) {
      return ProfileApiResult.error('Unsupported field: $trimmed');
    }
    return _postUpdate(
      token: token,
      attribute: attribute,
      record: value,
      targetDescription: trimmed,
    );
  }

  void close() => _client.close();

  Future<ProfileDataResult> fetchAllData({required String token}) async {
    // The FastAPI backend currently exposes mutation endpoints only.
    return const ProfileDataResult.error(
      'Remote profile sync is not available yet.',
    );
  }

  Future<ProfileApiResult> _postUpdate({
    required String token,
    required String attribute,
    required String record,
    required String targetDescription,
  }) async {
    final payload = jsonEncode({
      'token': token,
      'attribute': attribute,
      'record': record,
    });
    try {
      final response = await _client.post(
        _updateUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const ProfileApiResult.success();
      }
      String? serverMessage;
      if (response.body.isNotEmpty) {
        try {
          final Map<String, dynamic> body =
              jsonDecode(response.body) as Map<String, dynamic>;
          serverMessage = (body['detail'] ?? body['error'] ?? body['message'])
              as String?;
        } catch (_) {
          // ignore
        }
      }
      return ProfileApiResult.error(
        serverMessage ??
            'Failed to update $targetDescription (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const ProfileApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ProfileApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ProfileApiResult.error(
        'Unexpected error updating profile data.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class ProfileApiResult {
  const ProfileApiResult.success()
    : message = null,
      errorMessage = null,
      error = null,
      stackTrace = null;

  const ProfileApiResult.error(this.errorMessage, {this.error, this.stackTrace})
    : message = null;

  final String? message;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}

class ProfileDataResult {
  const ProfileDataResult.success({this.data})
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const ProfileDataResult.error(
    this.errorMessage, {
    this.error,
    this.stackTrace,
  }) : data = null;

  final Map<String, dynamic>? data;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => errorMessage == null;
}
