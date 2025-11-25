import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../presentation/widgets/auth_scaffold.dart';
import '../../presentation/widgets/pill_text_field.dart';
import '../../../../shared/widgets/field_label.dart';
import '../../../../shared/widgets/round_arrow_button.dart';
import '../../data/services/auth_api.dart';
import '../../data/storage/auth_session_storage.dart';
import '../../utils/notification_registration.dart';
import 'package:skill_up/features/home/presentation/pages/home_page.dart';
import 'package:skill_up/features/profile/data/user_profile_sync_service.dart';

class LoginPage extends StatefulWidget {
  static const route = '/login';
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _userC = TextEditingController();
  final _pwdC = TextEditingController();
  final _authApi = AuthApi();
  final _sessionStorage = AuthSessionStorage();
  bool _loading = false;

  @override
  void dispose() {
    _userC.dispose();
    _pwdC.dispose();
    _authApi.close();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    final username = _userC.text.trim();
    final password = _pwdC.text;

    try {
      final result = await _authApi.login(
        username: username,
        password: password,
      );

      if (result.isSuccess) {
        final session = result.session!;
        try {
          await _sessionStorage.saveSession(session);
          await UserProfileSyncService.instance.syncAll(
            token: session.token,
            username: session.username,
          );
        } catch (storageError, storageStackTrace) {
          if (kDebugMode) {
            debugPrint('Failed to finalize login data sync: $storageError');
            debugPrint(storageStackTrace.toString());
          }
        }
        unawaited(registerNotificationsForSession(session));
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text('Welcome back, ${session.username}!')),
        );
        Navigator.pushReplacementNamed(context, HomePage.route);
      } else {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? 'Login failed. Please retry.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (error, stackTrace) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Unexpected error. Please retry later.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      if (kDebugMode) {
        debugPrint('Login request threw: $error');
        debugPrint(stackTrace.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Login', // verrà mostrato grande come in Register
      form: Form(
        key: _formKey,
        child: Column(
          children: [
            const FieldLabel('Put your username:'),
            const SizedBox(height: 8),
            PillTextField(
              controller: _userC,
              hint: 'username',
              keyboardType: TextInputType.name,
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return 'Username required';
                return null;
              },
            ),
            const SizedBox(height: 14),
            const FieldLabel('Put your password:'),
            const SizedBox(height: 8),
            PillTextField(
              controller: _pwdC,
              hint: 'password',
              obscureText: true,
              validator: (v) =>
              (v == null || v.isEmpty) ? 'Password required' : null,
            ),
            const SizedBox(height: 22),
            RoundArrowButton(
              onPressed: _loading ? null : _submit,
              loading: _loading,
              svgAsset: 'assets/icons/send_icon.svg',
              iconSize: 32,
              tooltip: 'Accedi',
            ),
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.center,
        children: [
          Text(
            "You don’t have an account? ",
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.pushReplacementNamed(context, '/register'),
            child: const Text(
              "Register now",
              style: TextStyle(
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w800,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
