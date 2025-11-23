import 'package:flutter/material.dart';
import 'package:skill_up/features/auth/data/services/auth_api.dart';
import 'package:skill_up/features/auth/data/storage/auth_session_storage.dart';
import 'package:skill_up/features/auth/presentation/pages/login_page.dart';

/// Simple settings page with quick-access actions.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  static const route = '/settings';

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _authApi = AuthApi();
  final _sessionStorage = AuthSessionStorage();
  bool _loggingOut = false;

  @override
  void dispose() {
    _authApi.close();
    super.dispose();
  }

  Future<void> _handleLogout() async {
    if (_loggingOut) {
      return;
    }
    setState(() => _loggingOut = true);

    try {
      final session = await _sessionStorage.readSession();
      if (!mounted) {
        return;
      }
      if (session == null) {
        _showError('Nessuna sessione attiva.');
        return;
      }
      final result = await _authApi.logout(
        username: session.username,
        token: session.token,
      );
      if (!mounted) {
        return;
      }
      if (result.isSuccess) {
        await _sessionStorage.clearSession();
        if (!mounted) {
          return;
        }
        Navigator.pushNamedAndRemoveUntil(
          context,
          LoginPage.route,
          (_) => false,
        );
        return;
      }
      _showError(result.errorMessage ?? 'Logout non riuscito, riprova.');
    } catch (_) {
      if (!mounted) {
        return;
      }
      _showError('Errore inaspettato. Riprova.');
    } finally {
      if (mounted) {
        setState(() => _loggingOut = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const _GradientBackground(),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 18,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // 👇 freccia attaccata al bordo sinistro
                            Transform.translate(
                              offset: const Offset(-28, 0), // 👈 sposta a sinistra di quanto vale il padding
                              child: GestureDetector(
                                onTap: () => Navigator.of(context).maybePop(),
                                child: Container(
                                  width: 72,
                                  height: 56,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFB3B3B3),
                                    borderRadius: BorderRadius.horizontal(
                                      right: Radius.circular(28),
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 8,
                                        offset: Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.only(left: 14),
                                  alignment: Alignment.centerLeft,
                                  child: Image.asset(
                                    'assets/icons/back.png',
                                    width: 32,
                                    height: 32,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'SETTINGS',
                                  style: const TextStyle(
                                    fontFamily: 'FredokaOne',
                                    fontSize: 44,
                                    fontWeight: FontWeight.w900,
                                    fontStyle: FontStyle.italic, // se vuoi la leggera inclinazione
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 36),
                        _SettingsActionButton(
                          text: 'Change your password',
                          textStyle: buttonTextStyle,
                          onTap: () {},
                        ),
                        const SizedBox(height: 20),
                        _SettingsActionButton(
                          text: 'Frequently asked questions',
                          textStyle: buttonTextStyle,
                          onTap: () {},
                        ),
                        const SizedBox(height: 20),
                        _SettingsActionButton(
                          text: 'Send a feedback',
                          textStyle: buttonTextStyle,
                          onTap: () {},
                        ),
                        const SizedBox(height: 20),
                        _SettingsActionButton(
                          text: 'Information about the app',
                          textStyle: buttonTextStyle,
                          onTap: () {},
                        ),
                        const SizedBox(height: 36),
                        _LogoutButton(
                          onTap: _handleLogout,
                          loading: _loggingOut,
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFAD0C4), Color(0xFFFFCF71)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      ),
    );
  }
}

class _SettingsActionButton extends StatelessWidget {
  const _SettingsActionButton({
    required this.text,
    required this.onTap,
    this.textStyle,
  });

  final String text;
  final VoidCallback onTap;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(36), // 👈 più tondo
        child: Ink(
          height: 84,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(36), // 👈 più tondo
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.8),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              text,
              style: textStyle ??
                  const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.onTap, required this.loading});

  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final borderColor = Colors.white.withValues(alpha: 0.9);
    return Center( // 👈 per centrarlo orizzontalmente
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            width: 180,     // 👈 larghezza fissa più corta
            height: 80,     // già modificata
            decoration: BoxDecoration(
              color: const Color(0xFFE53935),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: borderColor, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Center(
              child: loading
                  ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
                  : const Text(
                'Logout',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
