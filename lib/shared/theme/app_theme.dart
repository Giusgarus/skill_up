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

    // Tutti i testi dell'app useranno Fredoka
    final fredokaTextTheme = GoogleFonts.fredokaTextTheme();

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: GoogleFonts.fredoka().fontFamily, // 👈 forza Fredoka ovunque

      textTheme: fredokaTextTheme.copyWith(
        // Titolo grande per AUTH e pagine principali
        headlineLarge: GoogleFonts.fredoka(
          fontSize: 40,
          letterSpacing: 1.2,
          color: Colors.white,
          height: 1.05,
          fontWeight: FontWeight.w700,
        ),

        // Label sopra ai campi
        labelLarge: GoogleFonts.fredoka(
          fontSize: 18,
          color: Colors.black.withValues(alpha: 0.9),
          height: 1.1,
          fontWeight: FontWeight.w600,
        ),

        // Testo base per descrizioni, bottoni, ecc.
        bodyMedium: GoogleFonts.fredoka(
          fontSize: 16,
          color: Colors.black.withValues(alpha: 0.85),
          fontWeight: FontWeight.w500,
        ),
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
        contentTextStyle: GoogleFonts.fredoka(
          color: colorScheme.onInverseSurface,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),

      scaffoldBackgroundColor: colorScheme.surface,
    );
  }
}