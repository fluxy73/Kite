import 'package:flutter/material.dart';

/// Tokens du design system Kite (cf. brand-spec.md).
class KiteColors {
  KiteColors._();

  static const bg = Color(0xFF0A0A0C);
  static const surface = Color(0xFF141416);
  static const surface2 = Color(0xFF1C1C20);
  static const surface3 = Color(0xFF242428);
  static const fg = Color(0xFFECECEA);
  static const muted = Color(0xFF8E8E93);
  static const border = Color(0xFF242428);
  static const accent = Color(0xFFD9985F);
  static const accentInk = Color(0xFF14100C);
  static const tint1 = Color(0xFF8B9CF5);
  static const tint2 = Color(0xFF57C9A3);
  static const tint3 = Color(0xFFE0B268);
  static const danger = Color(0xFFE5735F);

  static const bgLight = Color(0xFFF5F4F0);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surface2Light = Color(0xFFE8E6E0);
  static const fgLight = Color(0xFF1A1A1A);
  static const mutedLight = Color(0xFF6B6B6B);
  static const borderLight = Color(0xFFD4D2CC);
  static const accentLight = Color(0xFF1E4A7C);
}

/// Variante sombre (par défaut).
ThemeData kiteDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: KiteColors.bg,
    canvasColor: KiteColors.surface,
    cardColor: KiteColors.surface,
    dividerColor: KiteColors.border,
    colorScheme: const ColorScheme.dark(
      primary: KiteColors.accent,
      onPrimary: KiteColors.accentInk,
      secondary: KiteColors.tint2,
      surface: KiteColors.surface,
      onSurface: KiteColors.fg,
      error: KiteColors.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: KiteColors.bg,
      foregroundColor: KiteColors.fg,
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: KiteColors.fg,
      displayColor: KiteColors.fg,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: KiteColors.surface2,
      contentTextStyle: TextStyle(color: KiteColors.fg),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KiteColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: KiteColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: KiteColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: KiteColors.accent, width: 1.2),
      ),
    ),
  );
}

/// Variante claire.
ThemeData kiteLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: KiteColors.bgLight,
    cardColor: KiteColors.surfaceLight,
    dividerColor: KiteColors.borderLight,
    colorScheme: const ColorScheme.light(
      primary: KiteColors.accentLight,
      onPrimary: Colors.white,
      secondary: KiteColors.tint2,
      surface: KiteColors.surfaceLight,
      onSurface: KiteColors.fgLight,
      error: KiteColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: KiteColors.fgLight,
      displayColor: KiteColors.fgLight,
    ),
  );
}

/// Police display (serif) utilisée pour les titres d'écran.
const List<String> kDisplayFont = ['Georgia', 'Times New Roman', 'serif'];
