import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:skill_up/shared/network/backend_config.dart';

import '../../utils/password_validator.dart';

/// Thin wrapper around http client to keep API calls isolated from widgets.
class AuthApi {
  AuthApi({http.Client? client, String? baseUrl, Duration? requestTimeout})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? BackendConfig.defaultBaseUrl(),
      _requestTimeout = requestTimeout ?? _defaultRequestTimeout;

  final http.Client _client;
  final String baseUrl;
  final Duration _requestTimeout;

  static const _defaultRequestTimeout = Duration(seconds: 6);

  Uri get _registerUri => Uri.parse(baseUrl).resolve('/services/auth/register');
  Uri get _loginUri => Uri.parse(baseUrl).resolve('/services/auth/login');
  Uri get _logoutUri => Uri.parse(baseUrl).resolve('/services/auth/logout');
  Uri get _checkBearerUri =>
      Uri.parse(baseUrl).resolve('/services/auth/check_bearer');

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
      final response = await _post(
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
    } on TimeoutException catch (_) {
      return const AuthResult.error('Request timed out. Please retry.');
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
      final response = await _post(
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
    } on TimeoutException catch (_) {
      return const LoginResult.error('Request timed out. Please retry.');
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

  Future<BearerCheckResult> validateToken({
    required String token,
    String? usernameHint,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final payload = <String, dynamic>{
      'token': token,
      if (usernameHint != null && usernameHint.trim().isNotEmpty)
        'username': usernameHint.trim(),
    };
    try {
      final response = await _post(
        _checkBearerUri,
        headers: headers,
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) {
        Map<String, dynamic>? body;
        if (response.body.isNotEmpty) {
          try {
            body = jsonDecode(response.body) as Map<String, dynamic>;
          } catch (_) {
            return const BearerCheckResult.invalid(
              'Malformed server response.',
            );
          }
        }
        final isValid =
            body?['valid'] == true || body?['status'] == true;
        final username = body?['username'] as String?;
        if (isValid && username != null && username.trim().isNotEmpty) {
          return BearerCheckResult.valid(username.trim());
        }
        if (isValid) {
          return const BearerCheckResult.invalid(
            'Token validated but missing username.',
          );
        }
        return const BearerCheckResult.invalid('Token rejected by server.');
      }
      if (response.statusCode == 401) {
        return const BearerCheckResult.invalid('Invalid session token.');
      }
      String? message;
      if (response.body.isNotEmpty) {
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          message = body['detail'] as String?;
        } catch (_) {
          // ignore
        }
      }
      return BearerCheckResult.invalid(
        message ?? 'Unexpected status ${response.statusCode}.',
      );
    } on SocketException catch (_) {
      return const BearerCheckResult.error('Unable to reach the server.');
    } on HttpException catch (_) {
      return const BearerCheckResult.error('Unable to reach the server.');
    } on TimeoutException catch (_) {
      return const BearerCheckResult.error('Unable to reach the server.');
    } catch (error, stackTrace) {
      return BearerCheckResult.error(
        'Unexpected error while validating token.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<LogoutResult> logout({
    required String username,
    required String token,
  }) async {
    final payload = {'username': username, 'token': token};
    try {
      final response = await _post(
        _logoutUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );
      Map<String, dynamic>? body;
      if (response.body.isNotEmpty) {
        try {
          body = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          // Ignore body parsing errors and fall back to status code messaging.
        }
      }
      if (response.statusCode == 200) {
        final isValid =
            body?['valid'] == true || body?['status'] == true;
        if (isValid) {
          return const LogoutResult.success();
        }
        final message = body?['detail'] ?? body?['error'] ?? body?['message'];
        return LogoutResult.failure(
          (message is String ? message : null) ?? 'Logout rejected by server.',
          statusCode: response.statusCode,
        );
      }
      final message = body?['detail'] ?? body?['error'] ?? body?['message'];
      return LogoutResult.failure(
        (message is String ? message : null) ??
            'Logout failed. (${response.statusCode})',
        statusCode: response.statusCode,
      );
    } on SocketException catch (_) {
      return const LogoutResult.failure(
        'No internet connection. Please retry.',
        isConnectivityIssue: true,
      );
    } on HttpException catch (_) {
      return const LogoutResult.failure(
        'Unable to reach the server. Please retry.',
        isConnectivityIssue: true,
      );
    } on TimeoutException catch (_) {
      return const LogoutResult.failure(
        'Request timed out. Please retry.',
        isConnectivityIssue: true,
      );
    } catch (error, stackTrace) {
      return LogoutResult.failure(
        'Unexpected error while logging out.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void close() => _client.close();

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return _client
        .post(uri, headers: headers, body: body)
        .timeout(_requestTimeout);
  }

  AuthResult _toResult(http.Response response, {String? requestedUsername}) {
    Map<String, dynamic>? body;
    if (response.body.isNotEmpty) {
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        // Ignore body parsing errors and fall back to status code based messages.
      }
    }

    final isSuccess = response.statusCode == 200;
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
        session = AuthSession(
          token: token,
          username: resolvedUsername,
        );
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

    final isSuccess = response.statusCode == 200;
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
  const AuthSession({required this.token, required this.username});

  final String token;
  final String username;
}

class LogoutResult {
  const LogoutResult._({
    required this.isSuccess,
    this.errorMessage,
    this.statusCode,
    this.error,
    this.stackTrace,
    this.isConnectivityIssue = false,
  });

  const LogoutResult.success() : this._(isSuccess: true);

  const LogoutResult.failure(
    String message, {
    int? statusCode,
    Object? error,
    StackTrace? stackTrace,
    bool isConnectivityIssue = false,
  }) : this._(
         isSuccess: false,
         errorMessage: message,
         statusCode: statusCode,
         error: error,
         stackTrace: stackTrace,
         isConnectivityIssue: isConnectivityIssue,
       );

  final bool isSuccess;
  final String? errorMessage;
  final int? statusCode;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isConnectivityIssue;
}

class BearerCheckResult {
  const BearerCheckResult._({
    required this.isValid,
    this.username,
    this.errorMessage,
    this.error,
    this.stackTrace,
    this.isConnectivityIssue = false,
  });

  const BearerCheckResult.valid(String username)
    : this._(isValid: true, username: username);

  const BearerCheckResult.invalid([String? message])
    : this._(isValid: false, errorMessage: message);

  const BearerCheckResult.error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) : this._(
         isValid: false,
         errorMessage: message,
         error: error,
         stackTrace: stackTrace,
         isConnectivityIssue: true,
       );

  final bool isValid;
  final String? username;
  final String? errorMessage;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isConnectivityIssue;
}
