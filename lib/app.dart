import 'package:flutter/material.dart';
import 'shared/theme/app_theme.dart';
import 'features/auth/presentation/pages/login_page.dart';
import 'features/auth/presentation/pages/register_page.dart';
import 'features/home/presentation/pages/home_page.dart';

/// Root app that defines routes and theme.
class SkillUpApp extends StatelessWidget {
  const SkillUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkillUp',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(), // central place for typography/colors
      initialRoute: LoginPage.route,
      routes: {
        LoginPage.route: (_) => const LoginPage(),
        RegisterPage.route: (_) => const RegisterPage(),
        HomePage.route: (_) => const HomePage(),
      },
    );
  }
}
