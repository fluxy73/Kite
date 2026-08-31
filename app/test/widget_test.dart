import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/main.dart';
import 'package:kite/models.dart';
import 'package:kite/reminder_center.dart';

void main() {
  tearDown(() {
    // Arrête le timer périodique du rappel pour ne pas laisser de timer en attente.
    ScheduledReminderCenter.instance.stop();
    ScheduledReminderCenter.instance.reset();
  });

  testWidgets(
      'Kite charge le shell à onglets (Discussions/Communautés/Appels) '
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
