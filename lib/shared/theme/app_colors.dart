import 'package:flutter/material.dart';

/// Brand colors (e altre palette utili)
class AppColors {
  const AppColors._();

  static const Color brandPrimary   = Color(0xFFFF9A9E); // #FF9A9E
  static const Color brandSecondary = Color(0xFFFFD89B); // #FFD89B
}

/// Gradients centralizzati
class AppGradients {
  const AppGradients._();

  /// Auth/background gradient: #FF9A9E -> #FFD89B (top -> bottom)
  static const LinearGradient authBackground = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      AppColors.brandPrimary,
      AppColors.brandSecondary,
    ],
  );
}