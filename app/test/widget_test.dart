import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/main.dart';

void main() {
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
  });
}