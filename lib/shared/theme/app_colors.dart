import 'package:flutter/material.dart';

/// Centralized gradients and brand colors.
class AppGradients {
  const AppGradients._();

  /// Auth/background gradient: #FF9A9E -> #FFD89B (top -> bottom).
  static const LinearGradient authBackground = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFFFF9A9E), // from #FF9A9E
      Color(0xFFFFD89B), // to   #FFD89B
    ],
  );
}