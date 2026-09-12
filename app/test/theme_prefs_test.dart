import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/theme.dart';

/// Persistance du réglage de thème + résolution de la palette par mode.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kite-theme-test');
    ThemePrefs.resetForTest(dir: tmp.path);
  });

  tearDown(() {
    ThemePrefs.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('defaut = dark, set() filtre les valeurs invalides', () {
    expect(ThemePrefs.mode, 'dark');
    ThemePrefs.set('sepia');
    expect(ThemePrefs.mode, 'dark');
    ThemePrefs.set('light');
    expect(ThemePrefs.mode, 'light');
  });

  test('la preference survit : set() ecrit bien le fichier', () {
    ThemePrefs.set('light');
    final persisted = File('${tmp.path}/kite/kite-theme.json');
    expect(persisted.existsSync(), isTrue);
    expect(persisted.readAsStringSync(), contains('light'));
  });

  test('applyMode resout dark/light contre KiteColors et publie revision', () {
    final rev0 = KiteColors.revision.value;
    ThemePrefs.set('light');
    KiteColors.applyMode();
    expect(KiteColors.dark, isFalse);
    expect(KiteColors.revision.value, greaterThan(rev0));

    final rev1 = KiteColors.revision.value;
    ThemePrefs.set('dark');
    KiteColors.applyMode();
    expect(KiteColors.dark, isTrue);
    expect(KiteColors.revision.value, greaterThan(rev1));
  });

  test('kiteLightTheme en lin, kiteDarkTheme en ardoise', () {
    // Les builders lisent la palette globale : résoudre chaque mode.
    ThemePrefs.set('light');
    KiteColors.applyMode();
    final light = kiteLightTheme();
    expect(light.scaffoldBackgroundColor, const Color(0xFFF8F9FA));
    expect(light.colorScheme.primary, const Color(0xFF0EA5E9));

    ThemePrefs.set('dark');
    KiteColors.applyMode();
    final dark = kiteDarkTheme();
    expect(dark.scaffoldBackgroundColor, const Color(0xFF111418));
    expect(dark.colorScheme.primary, const Color(0xFF0284C7));
  });

  testWidgets('MaterialApp themeMode suit ThemePrefs (light)', (tester) async {
    ThemePrefs.set('light');
    KiteColors.applyMode();
    await tester.pumpWidget(
      MaterialApp(
        theme: kiteLightTheme(),
        darkTheme: kiteDarkTheme(),
        themeMode:
            ThemePrefs.mode == 'light' ? ThemeMode.light : ThemeMode.dark,
        home: Builder(
          builder: (ctx) {
            expect(Theme.of(ctx).brightness, Brightness.light);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();
  });
}
