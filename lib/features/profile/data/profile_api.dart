import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

class ProfileApi {
  ProfileApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _profilePicUri => Uri.parse(baseUrl).resolve('/set/profile_pic');
  Uri _fieldUri(String field) => Uri.parse(baseUrl).resolve('/set/$field');
  Uri get _userAllUri => Uri.parse(baseUrl).resolve('/user/get_all');

  Future<ProfileApiResult> uploadProfilePicture({
    required String token,
    required String base64Image,
  }) async {
    final payload = jsonEncode({'token': token, 'pic': base64Image});

    try {
      final response = await _client.post(
        _profilePicUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const ProfileApiResult.success();
      }
      return ProfileApiResult.error('Upload failed (${response.statusCode}).');
    } on SocketException catch (_) {
      return const ProfileApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ProfileApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ProfileApiResult.error(
        'Unexpected error uploading profile picture.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<ProfileApiResult> updateField({
    required String token,
    required String field,
    required String value,
  }) async {
    final payload = jsonEncode({'token': token, 'value': value});
    try {
      final response = await _client.post(
        _fieldUri(field),
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const ProfileApiResult.success();
      }
      return ProfileApiResult.error(
        'Failed to update $field (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const ProfileApiResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ProfileApiResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ProfileApiResult.error(
        'Unexpected error updating profile field.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void close() => _client.close();

  Future<ProfileDataResult> fetchAllData({required String token}) async {
    final payload = jsonEncode({'token': token});
    try {
      final response = await _client.post(
        _userAllUri,
        headers: const {'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body.isEmpty) {
          return const ProfileDataResult.success();
        }
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            return ProfileDataResult.success(data: decoded);
          }
          if (decoded is Map) {
            return ProfileDataResult.success(
              data: decoded.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            );
          }
          return const ProfileDataResult.success();
        } catch (_) {
          return const ProfileDataResult.error('Malformed server response.');
        }
      }
      return ProfileDataResult.error(
        'Failed to fetch user data (${response.statusCode}).',
      );
    } on SocketException catch (_) {
      return const ProfileDataResult.error('No internet connection.');
    } on HttpException catch (_) {
      return const ProfileDataResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return ProfileDataResult.error(
        'Unexpected error fetching user data.',
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
