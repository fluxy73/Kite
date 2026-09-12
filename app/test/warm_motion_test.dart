import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/ui/entrance.dart';
import 'package:kite/ui/swipe_to_reply.dart';

/// Régressions des trois défauts du passage warm-organic :
/// 1. l'entrée de message ne se rejoue pas au scroll-back (état « joué »
///    possédé par la liste, pas par la bulle) ;
/// 3. SwipeToReply n'accumule pas de listeners : le retour élastique d'un
///    second swipe part de la position du second swipe, pas du premier.
///
/// (2 — reprise de la pré-écoute vocale depuis la position réelle du
/// fichier — dépend de just_audio (canal plateforme), non instanciable
/// sous flutter_test : couvert par la relecture du code + usage réel.)
void main() {
  group('MessageEntrance : état possédé par la liste', () {
    testWidgets('animate:false rend l\'enfant sans couche d\'animation',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: MessageEntrance(animate: false, child: Text('recyclé')),
      ));
      await tester.pump();

      expect(find.text('recyclé'), findsOneWidget);
      // Enfant recyclé : aucun FadeTransition/SlideTransition de notre fait
      // (arbre nu : aucune transition de framework).
      expect(
        find.ancestor(
          of: find.text('recyclé'),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.text('recyclé'),
          matching: find.byType(SlideTransition),
        ),
        findsNothing,
      );
    });

    testWidgets('animate:true joue l\'entrée une fois puis se fige',
        (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: MessageEntrance(animate: true, child: Text('nouveau')),
      ));
      await tester.pump(); // démarre l'animation

      // Une seule couche : la nôtre (fade en cours).
      expect(
        find.ancestor(
          of: find.text('nouveau'),
          matching: find.byType(FadeTransition),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle(); // le ressort a atteint son settle
      final fade = tester.widget<FadeTransition>(find.byType(FadeTransition));
      // Settle asymptotique de la simulation physique (~0.9999993) —
      // indiscernable de 1 à l'écran.
      expect(fade.opacity.value, moreOrLessEquals(1.0, epsilon: 1e-3));
    });
  });

  group('SwipeToReply : un seul listener par retour élastique', () {
    double dragOffset(WidgetTester tester) {
      final t = tester.widget<Transform>(find.byType(Transform).first);
      return t.transform.getTranslation().x;
    }

    Future<void> swipe(WidgetTester tester, List<int> steps) async {
      final g = await tester.startGesture(const Offset(400, 300));
      for (final px in steps) {
        await g.moveBy(Offset(px.toDouble(), 0));
      }
      await g.up();
    }

    testWidgets('le second retour élastique part de SA position, pas du '
        'premier swipe (pas d\'accumulation de listeners)', (tester) async {
      var replies = 0;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SwipeToReply(
            onReply: () => replies++,
            // Enfant hit-testable (comme une vraie bulle opaque) : le
            // GestureDetector est en deferToChild.
            child: Container(width: 200, height: 60, color: Colors.white),
          ),
        ),
      ));
      await tester.pump();

      // Swipe 1 : trois mouvements (le slop du recogniseur mange le début)
      // → dépasse largement le seuil → réponse, retour, repos à 0.
      await swipe(tester, [40, 40, 80]);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(dragOffset(tester), moreOrLessEquals(0, epsilon: 0.5));

      // Swipe 2 : 20 px bruts (sous le seuil, pas de réponse). Avec le
      // défaut, le listener orphelin du swipe 1 rejouerait le profil du
      // premier retour (easeOutBack en overshoot négatif) : l'offset
      // repartirait sous 0 (~-20 px à 60 ms). Corrigé, le retour élastique
      // part de SA position : le ressort descend de ~20 vers 0 (~15 px
      // restants à 60 ms).
      await swipe(tester, [20]);
      await tester.pump(); // démarre le retour élastique
      await tester.pump(const Duration(milliseconds: 60));

      expect(replies, 1, reason: 'sous le seuil : pas de réponse');
      expect(dragOffset(tester), greaterThan(5),
          reason: 'le retour suit la position du second swipe '
              '(un listener orphelin le tirerait sous 0)');

      await tester.pumpAndSettle();
      expect(dragOffset(tester), moreOrLessEquals(0, epsilon: 0.5));

      // Rejouabilité : un troisième swipe complet répond encore.
      await swipe(tester, [40, 40, 80]);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(replies, 2);
    });
  });
}
