import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Lightweight client that registers Firebase device tokens with the backend.
class NotificationApi {
  NotificationApi({
    http.Client? client,
    this.baseUrl = _defaultBaseUrl,
  }) : _client = client ?? http.Client();

  static const String _defaultBaseUrl = 'http://127.0.0.1:8000';

  final http.Client _client;
  final String baseUrl;

  Uri get _registerUri => Uri.parse(baseUrl).resolve('/notifications/device');

  Future<bool> registerDevice({
    required String username,
    required String sessionToken,
    required String deviceToken,
    required String platform,
  }) async {
    final payload = <String, dynamic>{
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
