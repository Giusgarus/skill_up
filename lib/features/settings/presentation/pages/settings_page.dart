import 'package:flutter/material.dart';

/// Simple settings page with quick-access actions.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const route = '/settings';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.1,
    );
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            InkWell(
                              onTap: () => Navigator.of(context).maybePop(),
                              customBorder: const CircleBorder(),
                              child: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white.withValues(alpha: 0.2),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    width: 2,
                                  ),
                                ),
                                padding: const EdgeInsets.all(10),
                                child: Image.asset(
                                  'assets/icons/back.png',
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Text(
                                'SETTINGS',
                                style: titleStyle ??
                                    const TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
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
                        const SizedBox(height: 40),
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
        borderRadius: BorderRadius.circular(28),
        child: Ink(
          height: 84,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
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
