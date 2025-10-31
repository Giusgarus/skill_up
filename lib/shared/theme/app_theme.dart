import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  static ThemeData light() => _base(brightness: Brightness.light);
  static ThemeData dark() => _base(brightness: Brightness.dark);

  static ThemeData _base({required Brightness brightness}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.brandPrimary,
      brightness: brightness,
    );

    // Base body text with Poppins
    final baseText = GoogleFonts.poppinsTextTheme();

    // Title style for AUTH pages (LOGIN / REGISTRATION)
    final authTitle = GoogleFonts.fugazOne(
      fontSize: 40,
      letterSpacing: 1.2,
      color: Colors.white,
      height: 1.05,
    );

    // Label sopra ai campi
    final fieldLabel = GoogleFonts.fredoka(
      fontSize: 18,
      color: Colors.black.withValues(alpha: 0.9),
      height: 1.1,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: baseText.copyWith(
        // userai headlineLarge per il titolo AUTH
        headlineLarge: authTitle,
        // userai labelLarge per le etichette dei campi
        labelLarge: fieldLabel,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: brightness == Brightness.light
            ? Colors.white.withValues(alpha: 0.95)
            : colorScheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 22,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(40),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
      ),
      scaffoldBackgroundColor: colorScheme.surface,
    );
  }
}
