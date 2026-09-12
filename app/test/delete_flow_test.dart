import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/models.dart';
import 'package:kite/screens/conversation_screen.dart';

// =============================================================================
// Régression : le flux de suppression au appui long (double-pop corrigé), appui long sur une vraie
// bulle, l'appel traverse le menu extrait jusqu'aux callbacks de l'écran.
// =============================================================================

void main() {
  testWidgets('appui long -> Répondre affiche la barre de réponse',
      (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Un message des autres est rendu dans une vraie bulle.
    expect(find.text('salut du voisin'), findsOneWidget);

    // Appui long -> le menu extrait s'ouvre avec la barre de réactions.
    await tester.longPress(find.text('salut du voisin'));
    await tester.pumpAndSettle();
    expect(find.text('Répondre'), findsOneWidget);
    expect(find.text('Supprimer pour moi'), findsOneWidget);

    // Répondre -> la feuille se ferme et la barre de réponse apparaît.
    await tester.tap(find.text('Répondre'));
    await tester.pumpAndSettle();
    expect(find.text('Réponse à Lucas'), findsAtLeastNWidgets(1));
  });

  testWidgets('appui long -> Supprimer pour moi : confirmation puis retrait',
      (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.longPress(find.text('salut du voisin'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Supprimer pour moi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer pour moi'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    // Dialogue de confirmation extrait (toujours côté écran).
    expect(find.text('Supprimer pour moi ?'), findsOneWidget);
    await tester.tap(find.text('Supprimer').last);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    // Le message disparaît de la liste.
    expect(find.text('salut du voisin'), findsNothing);
  });

  testWidgets('supprimer pour tout le monde : retrait optimiste de la liste',
      (tester) async {
    final api = _ProbeApi(meOverride: 'u-lucas');
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Message à moi (meId = émetteur du seed) -> « pour tout le monde » ;
    // la branche removeWhere est celle du mode 'all'.
    await tester.longPress(find.text('salut du voisin'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Supprimer pour tout le monde'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer pour tout le monde'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer').last);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(api.deleted, isNotNull);
    expect(api.deleted!['id'], 'm-101');
    expect(api.deleted!['mode'], 'all');
    // Le message disparaît immédiatement de la liste (mise à jour optimiste).
    expect(find.text('salut du voisin'), findsNothing);
  });

  testWidgets('bouton app-bar Infos : la feuille infos conversation '
      's ouvre et ses tuiles appellent les actions de l ecran', (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Le bouton « Infos » de l'app bar (more_horiz) ouvre la feuille extraite.
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Lucas Martin'), findsWidgets);
    expect(find.text('Médias, liens et documents'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);

    // La tuile éphémères appelle bien le sélecteur de l'écran.
    await tester.ensureVisible(find.text('Messages éphémères'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Messages éphémères'));
    await tester.pumpAndSettle();
    expect(find.text('Désactivé'), findsOneWidget);
  });

  testWidgets('appui long -> Ajouter aux favoris : étoile persistée',
      (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.longPress(find.text('salut du voisin'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Ajouter aux favoris'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter aux favoris'));
    await tester.pumpAndSettle();
    expect(api.starred, ['m-101']);
  });

  testWidgets('appui long -> Informations : la feuille infos message '
      'affiche réactions et heure', (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.longPress(find.text('salut du voisin'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Informations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Informations'));
    await tester.pumpAndSettle();
    expect(find.text('Informations du message'), findsOneWidget);
  });
}

Chat _seedChat() => const Chat(
      id: 'c-test',
      type: 'dm',
      name: 'Lucas Martin',
      memberIds: ['u-julien', 'u-lucas'],
      adminIds: [],
    );

class _ProbeApi extends KiteApi {
  _ProbeApi({String? meOverride}) : _me = meOverride ?? 'u-julien', super('http://testserver');

  final String _me;
  final List<String> starred = [];
  Map<String, String>? deleted;

  @override
  String get meId => _me;

  @override
  Future<List<Message>> fetchMessages(String chatId) async => <Message>[
        Message(
          id: 'm-101',
          chatId: chatId,
          senderId: 'u-lucas',
          type: 'text',
          text: 'salut du voisin',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];

  @override
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {}

  @override
  Future<bool> toggleStar(String messageId) async {
    starred.add(messageId);
    return true;
  }

  @override
  Future<void> deleteMessage(String messageId, {String mode = 'me'}) async {
    deleted = {'id': messageId, 'mode': mode};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
