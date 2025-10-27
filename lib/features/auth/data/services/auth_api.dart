import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../utils/password_validator.dart';

/// Thin wrapper around http client to keep API calls isolated from widgets.
class AuthApi {
  AuthApi({http.Client? client, this.baseUrl = _defaultBaseUrl})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  static const _defaultBaseUrl = 'http://127.0.0.1:8000';

  Uri get _registerUri => Uri.parse(baseUrl).resolve('/register');
  Uri get _loginUri => Uri.parse(baseUrl).resolve('/login');

  Future<AuthResult> register({
    required String username,
    required String email,
    required String password,
  }) async {
    if (!isPasswordValid(password)) {
      return const AuthResult.error(kPasswordRequirementsSummary);
    }

    final payload = {
      'username': username,
      'email': email,
      'password': password,
    };

    try {
      final response = await _client.post(
        _registerUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      return _toResult(response, requestedUsername: username);
    } on SocketException catch (_) {
      return const AuthResult.error('No internet connection. Please retry.');
    } on HttpException catch (_) {
      return const AuthResult.error(
        'Unable to reach the server. Please retry.',
      );
    } on FormatException catch (_) {
      return const AuthResult.error('Malformed server response.');
    } catch (error, stackTrace) {
      return AuthResult.error(
        'Unexpected error while registering.',
        stackTrace: stackTrace,
        error: error,
      );
    }
  }

  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    final payload = {'username': username, 'password': password};

    try {
      final response = await _client.post(
        _loginUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      return _toLoginResult(response);
    } on SocketException catch (_) {
      return const LoginResult.error('No internet connection. Please retry.');
    } on HttpException catch (_) {
      return const LoginResult.error(
        'Unable to reach the server. Please retry.',
      );
    } on FormatException catch (_) {
      return const LoginResult.error('Malformed server response.');
    } catch (error, stackTrace) {
      return LoginResult.error(
        'Unexpected error while logging in.',
        stackTrace: stackTrace,
        error: error,
      );
    }
  }

  void close() => _client.close();

  AuthResult _toResult(http.Response response, {String? requestedUsername}) {
    Map<String, dynamic>? body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        // Ignore body parsing errors and fall back to status code based messages.
      }
    }

    final isSuccess = response.statusCode == 201;
    if (isSuccess) {
      final token = body?['token'] as String?;
      final responseUsername = body?['username'] as String?;
      final resolvedUsername = (responseUsername?.trim().isEmpty ?? true)
          ? (requestedUsername?.trim().isEmpty ?? true
                ? null
                : requestedUsername!.trim())
          : responseUsername!.trim();

      AuthSession? session;
      if (token != null && resolvedUsername != null) {
        session = AuthSession(token: token, username: resolvedUsername);
      }

      return AuthResult.success(
        session != null
            ? 'Welcome, ${session.username}!'
            : 'Registration completed.',
        statusCode: response.statusCode,
        session: session,
      );
    }

    final error = body?['detail'] ?? body?['error'] ?? body?['message'];
    return AuthResult.error(
      (error is String ? error : null) ??
          'Registration failed. (${response.statusCode})',
      statusCode: response.statusCode,
    );
  }

  LoginResult _toLoginResult(http.Response response) {
    Map<String, dynamic>? body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        // Ignore body parsing errors and fall back to status code based messages.
      }
    }

    final isSuccess = response.statusCode == 201;
    if (isSuccess) {
      final token = body?['token'] as String?;
      final username = body?['username'] as String?;
      if (token != null && username != null) {
        return LoginResult.success(
          AuthSession(token: token, username: username),
        );
      }
      return const LoginResult.error('Incomplete response from server.');
    }

    final error = body?['detail'] ?? body?['error'] ?? body?['message'];
    return LoginResult.error(
      (error is String ? error : null) ??
          'Login failed. (${response.statusCode})',
    );
  }
}

class AuthResult {
  const AuthResult.success(this.message, {this.statusCode, this.session})
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const AuthResult.error(
    this.errorMessage, {
    this.error,
    this.stackTrace,
    this.statusCode,
  }) : message = null,
       session = null;

  final String? message;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;
  final int? statusCode;
  final AuthSession? session;

  bool get isSuccess => errorMessage == null;
}

class LoginResult {
  const LoginResult.success(this.session)
    : errorMessage = null,
      error = null,
      stackTrace = null;

  const LoginResult.error(this.errorMessage, {this.error, this.stackTrace})
    : session = null;

  final AuthSession? session;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isSuccess => session != null;
}

class AuthSession {
  const AuthSession({required this.token, required this.username, this.userId});

  final String token;
  final String username;
  final String? userId;
}
