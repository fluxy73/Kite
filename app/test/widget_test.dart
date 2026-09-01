import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/main.dart';
import 'package:kite/models.dart';
import 'package:kite/reminder_center.dart';
import 'package:kite/screens/calls_screen.dart';

void main() {
  tearDown(() {
    // Arrête le timer périodique du rappel pour ne pas laisser de timer en attente.
    ScheduledReminderCenter.instance.stop();
    ScheduledReminderCenter.instance.reset();
  });

  testWidgets(
      'Kite charge le shell à onglets (Discussions/Appels) '
      'et affiche l\'état d\'erreur hors-ligne avec Réessayer',
      (tester) async {
    // flutter_test bloque le réseau : la requête du shell échoue
    // -> écran d'erreur avec Réessayer.
    await tester.pumpWidget(KiteApp(api: KiteApi('http://localhost:8080')));

    // Laisse le temps à la requête (HttpClient) d'échouer et rebuild.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('Réessayer'), findsOneWidget);

    // Arrête le timer périodique avant la fin du test (sinon timer en attente).
    ScheduledReminderCenter.instance.stop();
  });

  testWidgets("L'écran d'appel vidéo 1:1 affiche les options Flou et Portrait", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: InCallScreen(name: 'Lucas Martin', video: true)));
    expect(find.text('Flou'), findsOneWidget);
    expect(find.text('Paysage'), findsOneWidget);

    // Active le flou d'arrière-plan -> badge « Flou » sur la vignette (moi).
    await tester.tap(find.text('Flou'));
    await tester.pump();
    expect(find.text('Flou'), findsNWidgets(2));

    // Bascule le mode portrait (le bouton affiche « Paysage » avant activation).
    await tester.tap(find.text('Paysage'));
    await tester.pump();
    expect(find.text('Paysage'), findsNothing);
    expect(find.text('Portrait'), findsOneWidget);
  });

  testWidgets(
      'Le rappel affiche un popup quand un appel planifié avec rappel approche',
      (tester) async {
    await tester.pumpWidget(KiteApp(api: KiteApi('http://localhost:8080')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    // Simule la notification émise par le centre de rappels.
    ScheduledReminderCenter.instance.next.value = const ScheduledCall(
      id: 'sc-test',
      title: 'Point d’équipe',
      scheduledAt: 0,
      kind: 'video',
      reminder: true,
    );
    await tester.pump();

    expect(find.text('Rappel d’appel'), findsOneWidget);
    expect(find.text('Point d’équipe'), findsWidgets);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Rappel d’appel'), findsNothing);

    ScheduledReminderCenter.instance.stop();
  });
}
