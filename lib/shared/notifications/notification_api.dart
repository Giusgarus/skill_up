import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:skill_up/shared/network/backend_config.dart';

/// Lightweight client that registers Firebase device tokens with the backend.
class NotificationApi {
  NotificationApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl();

  final http.Client _client;
  final String baseUrl;

  Uri get _registerUri =>
      Uri.parse(baseUrl).resolve('/services/notifications/device');

  Future<bool> registerDevice({
    required String username,
    required String sessionToken,
    required String deviceToken,
    required String platform,
    String? userId,
  }) async {
    final normalizedUserId = userId?.trim();
    if (normalizedUserId == null || normalizedUserId.isEmpty) {
      if (kDebugMode) {
        debugPrint('Skipping device registration: missing user id.');
      }
      return false;
    }
    final payload = <String, dynamic>{
      'user_id': normalizedUserId,
      'username': username,
      'session_token': sessionToken,
      'device_token': deviceToken,
      'platform': platform,
    };

    try {
      final response = await _client.post(
        _registerUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) {
        return true;
      }
      if (kDebugMode) {
        debugPrint(
          'Failed to register device token: '
          'status ${response.statusCode} body ${response.body}',
        );
      }
      return false;
    } on SocketException catch (_) {
      if (kDebugMode) {
        debugPrint('No internet while registering device token.');
      }
      return false;
    } on HttpException catch (error) {
      if (kDebugMode) {
        debugPrint('HTTP exception while registering token: $error');
      }
      return false;
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Unexpected error registering device token: $error');
        debugPrint(stackTrace.toString());
      }
      return false;
    }
  }

  void close() => _client.close();
}
