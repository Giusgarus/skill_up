import 'package:flutter/material.dart';
import '../../../../shared/widgets/logo.dart';

class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget form;
  final Widget footer;

  /// Optional: if provided, replaces the default text title.
  final Widget? titleWidget;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.form,
    required this.footer,
    this.titleWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        // gradient già preso dai tuoi theme/colors
        decoration: const BoxDecoration(
          // AppGradients.authBackground, se lo stai usando
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF9A9E), Color(0xFFFFD89B)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const AppLogo(),
                    const SizedBox(height: 8),

                    // ⬇️ Se c'è un titleWidget (SVG), usalo; altrimenti testo
                    if (titleWidget != null)
                      titleWidget!
                    else
                      Text(
                        title.toUpperCase(),
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),

                    const SizedBox(height: 16),
                    form,
                    const SizedBox(height: 24),
                    footer,
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}