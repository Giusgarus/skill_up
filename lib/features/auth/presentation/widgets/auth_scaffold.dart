import 'package:flutter/material.dart';
import '../../../../shared/theme/app_colors.dart';   // <— aggiungi questo import
import '../../../../shared/widgets/logo.dart';

class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget form;
  final Widget footer;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.form,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: AppGradients.authBackground, // <— usa il gradient centralizzato
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
                    Text(
                      title.toUpperCase(),
                      style: Theme.of(context).textTheme.headlineLarge, // <— usa il tema
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