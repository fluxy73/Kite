import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Tokens du design system Kite — palette « warm organic » :
/// neutres chauds (ardoise/lin), teal profond, vert sauge, terracotta.
///
/// Les tokens sont des **static getters pilotés par le mode** : chaque
/// surface lit `KiteColors.x` comme avant, et la valeur résout selon le
/// thème courant ([dark] / [setMode]). Le mode est persisté sur disque
/// (`kite-theme.json`, même mécanisme hors-ligne que le verrou/brouillons).
/// (cf. brand-spec.md)
class KiteColors {
  KiteColors._();

  static bool _dark = true;

  /// true = palette sombre (défaut).
  static bool get dark => _dark;

  /// Incrémenté à chaque changement de configuration de thème (mode
  /// persisté ou palette résolue) — KiteApp écoute pour rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Bascule la palette (appelé par KiteApp avant le premier build et à
  /// chaque changement de réglage, puis rebuild de MaterialApp).
  static void setDark(bool value) => _dark = value;

  /// Résout le mode persisté ([ThemePrefs.mode]) contre la luminosité
  /// plateforme et applique la palette correspondante.
  static void applyMode() {
    final mode = ThemePrefs.mode;
    final dark = mode == 'dark' ||
        (mode == 'system' &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark);
    setDark(dark);
    revision.value++;
  }

  // --- Sombre : ardoise chaude profonde (jamais de noir pur) ---
  static const _bgDark = Color(0xFF111418);
  static const _surfaceDark = Color(0xFF181C22);
  static const _surface2Dark = Color(0xFF1F242B);
  static const _surface3Dark = Color(0xFF272D35);

  // --- Clair : lin / albâtre chaud ---
  static const _bgLight = Color(0xFFF8F9FA);
  static const _surfaceLight = Color(0xFFFFFFFF);
  static const _surface2Light = Color(0xFFF3F4F6);
  static const _surface3Light = Color(0xFFE9ECEF);

  // --- Neutres ---
  static Color get bg => _dark ? _bgDark : _bgLight;
  static Color get surface => _dark ? _surfaceDark : _surfaceLight;
  static Color get surface2 => _dark ? _surface2Dark : _surface2Light;
  static Color get surface3 => _dark ? _surface3Dark : _surface3Light;
  static Color get fg => _dark ? const Color(0xFFE9E7E2) : const Color(0xFF1B1E23);
  static Color get muted =>
      _dark ? const Color(0xFF8A8F98) : const Color(0xFF667085);

  /// Liseré délicat (~12-14 %) : frontière tactile, pas de trait dur.
  static Color get border =>
      _dark ? const Color(0x24FFFFFF) : const Color(0x1F101828);

  // --- Accents ancrés nature (identiques dans les deux modes, teal
  // légèrement lumineux en clair pour le contraste) ---
  static Color get accent => _dark ? const Color(0xFF0284C7) : const Color(0xFF0EA5E9);
  static Color get accentInk =>
      _dark ? const Color(0xFFF8FAFC) : Colors.white;
  static Color get tint1 => _dark ? const Color(0xFF8FA3F0) : const Color(0xFF5B6BD6);
  static Color get tint2 => _dark ? const Color(0xFF4CC38A) : const Color(0xFF2FA36B);
  static Color get tint3 => _dark ? const Color(0xFFE3B475) : const Color(0xFFB98A3F);
  static Color get danger => const Color(0xFFEF4444);

  /// Éphémère / attention : terracotta douce (éléments auto-destructeurs).
  static Color get ephemeral =>
      _dark ? const Color(0xFFEA580C) : const Color(0xFFC2410C);

  /// Succès / en ligne : sauge feuille, jamais de néon.
  static Color get sage => _dark ? const Color(0xFF22C55E) : const Color(0xFF16A34A);

  /// Ombre ambiante douce, diffuse multi-couches — jamais d'ombre dure
  /// (plus marquée en clair pour détacher les surfaces du lin).
  static List<BoxShadow> softShadow() => _dark
      ? const [
          BoxShadow(
              color: Color(0x40000000),
              blurRadius: 24,
              offset: Offset(0, 8),
              spreadRadius: -6),
          BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ]
      : const [
          BoxShadow(
              color: Color(0x14101828),
              blurRadius: 24,
              offset: Offset(0, 8),
              spreadRadius: -6),
          BoxShadow(
              color: Color(0x0A101828),
              blurRadius: 8,
              offset: Offset(0, 2)),
        ];

  /// Police UI : Inter (humaniste, terminaisons rondes), avec repli natif
  /// par plateforme si la ressource manque.
  static const uiFont = 'Inter';
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

/// Variante sombre.
ThemeData kiteDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: KiteColors.bg,
    canvasColor: KiteColors.surface,
    cardColor: KiteColors.surface,
    dividerColor: KiteColors.border,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF0284C7),
      onPrimary: Color(0xFFF8FAFC),
      secondary: Color(0xFF4CC38A),
      surface: Color(0xFF181C22),
      onSurface: Color(0xFFE9E7E2),
      error: Color(0xFFEF4444),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF111418),
      foregroundColor: Color(0xFFE9E7E2),
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: _kiteText(base.textTheme, KiteColors.fg),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: KiteColors.surface2,
      contentTextStyle: TextStyle(color: KiteColors.fg),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KiteColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(color: KiteColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(color: KiteColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: Color(0xFF0284C7), width: 1.2),
      ),
    ),
  );
}

/// Variante claire — lin / albâtre, mêmes accents.
ThemeData kiteLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: KiteColors.bg,
    canvasColor: KiteColors.surface,
    cardColor: KiteColors.surface,
    dividerColor: KiteColors.border,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF0EA5E9),
      onPrimary: Colors.white,
      secondary: Color(0xFF2FA36B),
      surface: Colors.white,
      onSurface: Color(0xFF1B1E23),
      error: Color(0xFFEF4444),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFF8F9FA),
      foregroundColor: Color(0xFF1B1E23),
      elevation: 0,
      centerTitle: false,
    ),
    textTheme: _kiteText(base.textTheme, KiteColors.fg),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: KiteColors.surface2,
      contentTextStyle: TextStyle(color: KiteColors.fg),
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KiteColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(color: KiteColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: BorderSide(color: KiteColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(22),
        borderSide: const BorderSide(color: Color(0xFF0EA5E9), width: 1.2),
      ),
    ),
  );
}

/// Réglage de thème persisté : 'dark' | 'light' | 'system'.
/// Fichier lu/écrit en synchrone (même pattern que ChatLockStore/DraftStore)
/// pour que la palette soit correcte avant le premier frame.
class ThemePrefs {
  ThemePrefs._();

  static const _default = 'dark';
  static String _mode = _read();

  /// Répertoire injecté (tests uniquement) — null = emplacement normal.
  static String? _overrideDir;

  /// Recharge depuis un répertoire donné (tests) ou l'emplacement normal.
  static void resetForTest({String? dir}) {
    _overrideDir = dir;
    _mode = _read();
  }

  static String _file() {
    try {
      final base = _overrideDir ??
          (Platform.isWindows
              ? (Platform.environment['APPDATA'] ?? Directory.current.path)
              : (Platform.environment['HOME'] ?? Directory.current.path));
      final dir = Directory('$base/kite');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}${Platform.pathSeparator}kite-theme.json';
    } catch (_) {
      return 'kite-theme.json';
    }
  }

  static String _read() {
    try {
      final f = File(_file());
      if (!f.existsSync()) return _default;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return j['mode'] as String? ?? _default;
    } catch (_) {
      return _default;
    }
  }

  /// Mode courant persisté.
  static String get mode => _mode;

  static void set(String mode) {
    if (mode != 'dark' && mode != 'light' && mode != 'system') return;
    _mode = mode;
    try {
      File(_file()).writeAsStringSync(jsonEncode({'mode': mode}));
    } catch (_) {
      // Persistance best-effort (tests, FS lecture seule).
    }
  }
}

/// Police display (serif) utilisée pour les titres d'écran.
const List<String> kDisplayFont = ['Georgia', 'Times New Roman', 'serif'];
