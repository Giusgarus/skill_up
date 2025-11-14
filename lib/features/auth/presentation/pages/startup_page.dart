import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/auth/utils/notification_registration.dart';
import 'package:skill_up/features/home/presentation/pages/home_page.dart';

import 'login_page.dart';

/// Lightweight gate that restores a persisted session (if any) and routes
/// the user without blocking on remote validation.
class StartupPage extends StatefulWidget {
  const StartupPage({super.key});

  static const route = '/';

  @override
  State<StartupPage> createState() => _StartupPageState();
}

class _StartupPageState extends State<StartupPage> {
  final AuthSessionStorage _sessionStorage = AuthSessionStorage();
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

      unawaited(registerNotificationsForSession(session));
      _goTo(HomePage.route);
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
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
