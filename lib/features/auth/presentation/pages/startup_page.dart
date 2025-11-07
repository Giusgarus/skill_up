import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/home/presentation/pages/home_page.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';
import 'package:skill_up/shared/notifications/notification_service.dart';

import 'login_page.dart';

/// Lightweight gate that restores a persisted session, validates it via
/// the backend, and redirects to the appropriate screen.
class StartupPage extends StatefulWidget {
  const StartupPage({super.key});

  static const route = '/';

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  final AuthSessionStorage _sessionStorage = AuthSessionStorage();
  late final AuthApi _authApi = AuthApi();
  bool _navigatedAway = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final session = await _sessionStorage.readSession();
      if (!mounted) return;

      if (session == null) {
        _goTo(LoginPage.route);
        return;
      }

      final result = await _authApi.validateToken(
        token: session.token,
        usernameHint: session.username,
      );
      if (!mounted) return;

      if (result.isValid) {
        final normalizedUsername = (result.username?.trim().isNotEmpty ?? false)
            ? result.username!.trim()
            : session.username;
        var activeSession = session;
        if (normalizedUsername != session.username) {
          activeSession = AuthSession(
            token: session.token,
            username: normalizedUsername,
          );
          await _sessionStorage.saveSession(activeSession);
        }
        unawaited(
          UserProfileSyncService.instance.syncAll(
            token: session.token,
            username: normalizedUsername,
          ),
        );
        unawaited(NotificationService.instance.registerSession(activeSession));
        _goTo(HomePage.route);
        return;
      }

      if (result.isConnectivityIssue) {
        unawaited(NotificationService.instance.registerSession(session));
        _goTo(HomePage.route);
        return;
      }

      await _sessionStorage.clearSession();
      _goTo(LoginPage.route);
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Failed to resume session: $error');
        debugPrint(stackTrace.toString());
      }
      if (!mounted) return;
      _goTo(HomePage.route);
    }
  }

  void _goTo(String route) {
    if (_navigatedAway) return;
    _navigatedAway = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, route);
    });
  }

  @override
  void dispose() {
    _authApi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
