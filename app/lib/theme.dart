import 'package:flutter/material.dart';

/// Tokens du design system Kite — palette « warm organic » :
/// neutres chauds (ardoise/lin), teal profond, vert sauge, terracotta.
/// (cf. brand-spec.md)
class KiteColors {
  KiteColors._();

  // --- Sombre : ardoise chaude profonde (jamais de noir pur) ---
  static const bg = Color(0xFF111418);
  static const surface = Color(0xFF181C22);
  static const surface2 = Color(0xFF1F242B);
  static const surface3 = Color(0xFF272D35);
  static const fg = Color(0xFFE9E7E2);
  static const muted = Color(0xFF8A8F98);

  /// Liseré délicat : blanc ~14 % (frontière tactile, pas de trait dur).
  static const border = Color(0x24FFFFFF);

  // --- Accents ancrés nature ---
  static const accent = Color(0xFF0284C7); // teal océan profond
  static const accentInk = Color(0xFFF8FAFC); // texte sur teal
  static const tint1 = Color(0xFF8FA3F0); // lavande douce (noms d'expéditeur)
  static const tint2 = Color(0xFF4CC38A); // vert sauge clair
  static const tint3 = Color(0xFFE3B475); // sable chaud
  static const danger = Color(0xFFEF4444);

  /// Éphémère / attention : terracotta douce (éléments auto-destructeurs).
  static const ephemeral = Color(0xFFEA580C);

  /// Succès / en ligne : sauge feuille, jamais de néon.
  static const sage = Color(0xFF22C55E);

  // --- Clair : lin / albâtre chaud ---
  static const bgLight = Color(0xFFF8F9FA);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const surface2Light = Color(0xFFF3F4F6);
  static const fgLight = Color(0xFF1B1E23);
  static const mutedLight = Color(0xFF667085);

  /// Liseré clair : encre ~12 %.
  static const borderLight = Color(0x1F101828);
  static const accentLight = Color(0xFF0EA5E9); // teal lumineux
  static const sageLight = Color(0xFF16A34A);

  /// Ombre ambiante douce, diffuse multi-couches — jamais d'ombre dure.
  /// `light` : version pour surfaces claires (plus transparente).
  static List<BoxShadow> softShadow({bool light = false}) => light
      ? const [
          BoxShadow(
              color: Color(0x14101828),
              blurRadius: 24,
              offset: Offset(0, 8),
              spreadRadius: -6),
          BoxShadow(
              color: Color(0x0A101828),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ]
      : const [
          BoxShadow(
              color: Color(0x40000000),
              blurRadius: 24,
              offset: Offset(0, 8),
              spreadRadius: -6),
          BoxShadow(color: Color(0x1A000000), blurRadius: 8, offset: Offset(0, 2)),
        ];

  /// Police UI : Inter (humaniste, terminaisons rondes), avec repli natif
  /// par plateforme si la ressource manque.
  static const uiFont = 'Inter';
  static const fontFallback = ['SF Pro Text', 'Segoe UI', 'Roboto'];
}

/// Construction du textTheme : couleurs Kite + hauteurs 1.4–1.5 (lisible,
/// chaleureux) sur les styles de corps.
TextTheme _kiteText(TextTheme base, Color fg) => base
    .copyWith(
      bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
      bodySmall: base.bodySmall?.copyWith(height: 1.4),
      titleLarge: base.titleLarge?.copyWith(height: 1.3),
      titleMedium: base.titleMedium?.copyWith(height: 1.35),
      labelLarge: base.labelLarge?.copyWith(letterSpacing: 0.15),
      labelMedium: base.labelMedium?.copyWith(letterSpacing: 0.15),
    )
    .apply(bodyColor: fg, displayColor: fg, fontFamily: KiteColors.uiFont);

/// Variante sombre (par défaut).
ThemeData kiteDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: KiteColors.bg,
    canvasColor: KiteColors.surface,
    cardColor: KiteColors.surface,
    dividerColor: KiteColors.border,
    splashFactory: InkSparkle.splashFactory,
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
    textTheme: _kiteText(base.textTheme, KiteColors.fg),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: KiteColors.surface2,
      contentTextStyle: TextStyle(color: KiteColors.fg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KiteColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: KiteColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: KiteColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
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
    canvasColor: KiteColors.surfaceLight,
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
    appBarTheme: const AppBarTheme(
      backgroundColor: KiteColors.bgLight,
      foregroundColor: KiteColors.fgLight,
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: _kiteText(base.textTheme, KiteColors.fgLight),
  );
}

/// Police display (serif) utilisée pour les titres d'écran.
const List<String> kDisplayFont = ['Georgia', 'Times New Roman', 'serif'];
