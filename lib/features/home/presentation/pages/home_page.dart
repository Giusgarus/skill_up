import 'package:flutter/material.dart';

/// Stand-in for the main application page shown after authentication.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const route = '/home';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SkillUp')),
      body: const Center(
        child: Text(
          'Welcome to SkillUp!',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
