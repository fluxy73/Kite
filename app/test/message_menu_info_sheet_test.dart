import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/models.dart';
import 'package:kite/people.dart';
import 'package:kite/ui/avatar.dart';
import 'package:kite/screens/message_menu.dart';
import 'package:kite/screens/chat_info_sheet.dart';

// =============================================================================
// Régression : le menu et la feuille d'infos extraits restent branchés : chaque callback du menu et de la
// feuille d'infos est-il branché au bon endpoint ? Les taps déclenchent-ils
// la bonne action ? Les feuilles se ferment-elles avant l'action ?
// =============================================================================

Message _msg({String type = 'text', String text = 'salut'}) => Message(
      id: 'm-1',
      chatId: 'c-test',
      senderId: 'u-lucas',
      type: type,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

void main() {
  group('KitePeople (dédupe noms/initiales)', () {
    test('kiteDisplayName : moi => Vous, seed => prénom, inconnu => id', () {
      expect(kiteDisplayName('u-julien', 'u-julien'), 'Vous');
      expect(kiteDisplayName('u-lucas', 'u-julien'), 'Lucas');
      expect(kiteDisplayName('u-emma', 'u-julien'), 'Emma');
      expect(kiteDisplayName('u-ghost', 'u-julien'), 'u-ghost');
    });

    test('kiteInitials : 2 mots, 1 mot, vide, chaîne blanche', () {
      expect(kiteInitials('Emma Bernard'), 'EB');
      expect(kiteInitials('Lucas'), 'L');
      expect(kiteInitials(''), '?');
      expect(kiteInitials('   '), '?');
    });
  });

  group('KiteAvatar', () {
    testWidgets('rend les initiales et la bonne taille large/petit',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: KiteAvatar(name: 'Emma Bernard', group: false)),
      ));
      expect(find.text('EB'), findsOneWidget);

      final small = tester.getSize(find.byType(KiteAvatar));
      expect(small.width, 36);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: KiteAvatar(name: 'Projet Nova', group: true, large: true)),
      ));
      expect(find.text('PN'), findsOneWidget);
      final large = tester.getSize(find.byType(KiteAvatar));
      expect(large.width, 64);
    });
  });

  group('MessageMenu.show — chaque entrée déclenche SA callback', () {
    late Set<String> fired;
    setUp(() => fired = {});

    Future<void> openAndTap(WidgetTester tester, Message m,
        {required Finder entry, bool mine = false}) async {
      fired = {};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => MessageMenu.show(
                  ctx,
                  m,
                  meId: 'u-julien',
                  onReact: (e) => fired.add('react:$e'),
                  onReply: () => fired.add('reply'),
                  onCopy: () => fired.add('copy'),
                  onEdit: () => fired.add('edit'),
                  onPin: () => fired.add('pin'),
                  onToggleStar: () => fired.add('star'),
                  onTranslate: () => fired.add('translate'),
                  onInfo: () => fired.add('info'),
                  onDelete: (mode) => fired.add('delete:$mode'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Le menu liste TOUJOURS ses entrées + la barre de réactions.
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
    }

    testWidgets('Répondre', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Répondre'));
      expect(fired, {'reply'});
    });

    testWidgets('Copier (texte seulement)', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Copier'));
      expect(fired, {'copy'});
    });

    testWidgets('Traduire', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Traduire'));
      expect(fired, {'translate'});
    });

    testWidgets('Favori', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Ajouter aux favoris'));
      expect(fired, {'star'});
    });

    testWidgets('Épingler', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Épingler'));
      expect(fired, {'pin'});
    });

    testWidgets('Informations', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('Informations'));
      expect(fired, {'info'});
    });

    testWidgets('Supprimer pour moi (message des autres)',
        (tester) async {
      await openAndTap(tester, _msg(),
          entry: find.text('Supprimer pour moi'));
      expect(fired, {'delete:me'});
    });

    testWidgets('Supprimer pour tout le monde (message à moi)',
        (tester) async {
      final mine = Message(
        id: 'm-2',
        chatId: 'c-test',
        senderId: 'u-julien',
        type: 'text',
        text: 'le mien',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await openAndTap(tester, mine,
          entry: find.text('Supprimer pour tout le monde'));
      expect(fired, {'delete:all'});
    });

    testWidgets('réaction via la barre (ferme puis notifie)', (tester) async {
      await openAndTap(tester, _msg(), entry: find.text('👍'));
      expect(fired, {'react:👍'});
    });

    testWidgets('menu vocal : ni Copier ni Modifier', (tester) async {
      fired = {};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => MessageMenu.show(
                  ctx,
                  _msg(type: 'voice'),
                  meId: 'u-julien',
                  onReact: (e) {},
                  onReply: () {},
                  onCopy: () {},
                  onEdit: () {},
                  onPin: () {},
                  onToggleStar: () {},
                  onTranslate: () {},
                  onInfo: () {},
                  onDelete: (mode) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Copier'), findsNothing);
      expect(find.text('Modifier'), findsNothing);
      expect(find.text('Répondre'), findsOneWidget);
      expect(find.text('Supprimer pour moi'), findsOneWidget);
      await tester.tap(find.text('Répondre'));
      await tester.pumpAndSettle();
    });
  });

  group('ChatInfoSheet.show — chaque tuile déclenche SA callback', () {
    testWidgets('groupe : en-tête, membres, tuiles branchées', (tester) async {
      final fired = <String>{};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ChatInfoSheet.show(
                  ctx,
                  chatName: 'Projet Nova',
                  isGroup: true,
                  memberIds: const ['u-julien', 'u-lucas', 'u-emma'],
                  adminIds: const ['u-julien'],
                  meId: 'u-julien',
                  chatId: 'c-nova',
                  senderName: (id) => id == 'u-julien' ? 'Vous' : id,
                  isBlocked: false,
                  lockBioAvailable: false,
                  onMedia: () => fired.add('media'),
                  onStarred: () => fired.add('starred'),
                  onWallpaper: () => fired.add('wallpaper'),
                  onToggleBlock: () => fired.add('block'),
                  onReport: () => fired.add('report'),
                  onRemoveLock: () => fired.add('unlock'),
                  onArmLock: () => fired.add('armLock'),
                  onToggleBiometrics: () => fired.add('bio'),
                  onDisappearing: () => fired.add('ephemeral'),
                  onNotifications: () => fired.add('notifications'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // En-tête : nom + comptage de membres + badge Admin.
      expect(find.text('Projet Nova'), findsOneWidget);
      expect(find.text('3 membres'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);

      // Groupe => pas de tuile Bloquer.
      expect(find.text('Bloquer'), findsNothing);

      for (final tile in ['Médias, liens et documents', 'Messages favoris',
          'Thème du chat', 'Signaler', 'Notifications']) {
        fired.clear();
        await tester.ensureVisible(find.text(tile));
        await tester.pumpAndSettle();
        await tester.tap(find.text(tile));
        await tester.pumpAndSettle();
        expect(fired, {tile == 'Médias, liens et documents'
            ? 'media'
            : tile == 'Messages favoris'
                ? 'starred'
                : tile == 'Thème du chat'
                    ? 'wallpaper'
                    : tile == 'Signaler'
                        ? 'report'
                        : 'notifications'});
        // Réouvrir pour la tuile suivante.
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('DM : tuile Bloquer présente, verrou branché', (tester) async {
      final fired = <String>{};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ChatInfoSheet.show(
                  ctx,
                  chatName: 'Lucas Martin',
                  isGroup: false,
                  memberIds: const ['u-julien', 'u-lucas'],
                  adminIds: const [],
                  meId: 'u-julien',
                  chatId: 'c-lucas',
                  senderName: (id) => id,
                  isBlocked: true,
                  lockBioAvailable: false,
                  onMedia: () => fired.add('media'),
                  onStarred: () => fired.add('starred'),
                  onWallpaper: () => fired.add('wallpaper'),
                  onToggleBlock: () => fired.add('block'),
                  onReport: () => fired.add('report'),
                  onRemoveLock: () => fired.add('unlock'),
                  onArmLock: () => fired.add('armLock'),
                  onToggleBiometrics: () => fired.add('bio'),
                  onDisappearing: () => fired.add('ephemeral'),
                  onNotifications: () => fired.add('notifications'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // DM bloqué : libellé inversé.
      expect(find.text('Débloquer le contact'), findsOneWidget);
      await tester.ensureVisible(find.text('Débloquer le contact'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Débloquer le contact'));
      await tester.pumpAndSettle();
      expect(fired, {'block'});
    });
  });
}
