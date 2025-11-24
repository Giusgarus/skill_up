import 'package:flutter/material.dart';
import 'shared/theme/app_theme.dart';
import 'features/auth/presentation/pages/login_page.dart';
import 'features/auth/presentation/pages/register_page.dart';
import 'features/auth/presentation/pages/startup_page.dart';
import 'features/home/presentation/pages/monthly_medals_page.dart';
import 'features/home/presentation/pages/home_page.dart';
import 'features/home/presentation/pages/statistics_page.dart';
import 'features/profile/presentation/pages/user_info_page.dart';
import 'features/settings/presentation/pages/settings_page.dart';
import 'features/home/presentation/pages/plan_overview.dart';

/// Root app that defines routes and theme.
class SkillUpApp extends StatelessWidget {
  const SkillUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkillUp',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(), // central place for typography/colors
      initialRoute: StartupPage.route,
      routes: {
        StartupPage.route: (_) => const StartupPage(),
        LoginPage.route: (_) => const LoginPage(),
        RegisterPage.route: (_) => const RegisterPage(),
        HomePage.route: (_) => const HomePage(),
        UserInfoPage.route: (_) => const UserInfoPage(),
        SettingsPage.route: (_) => const SettingsPage(),
        PlanOverviewPage.route: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          if (args is PlanOverviewArgs) {
            return PlanOverviewPage(args: args);
          }
          return const Scaffold(
            body: Center(child: Text('Missing plan details')),
          );
        },
        MonthlyMedalsPage.route: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          final initial = args is DateTime ? args : DateTime.now();
          return MonthlyMedalsPage(initialMonth: initial);
        },
        StatisticsPage.route: (context) {
          final args = ModalRoute.of(context)?.settings.arguments;
          int? initialYear;
          int? initialMonth;
          if (args is Map<String, dynamic>) {
            final yearValue = args['year'];
            final monthValue = args['month'];
            if (yearValue is int) {
              initialYear = yearValue;
            }
            if (monthValue is int) {
              initialMonth = monthValue;
            }
          }
          return StatisticsPage(
            initialYear: initialYear,
            initialMonth: initialMonth,
          );
        },
      },
    );
  }
}
