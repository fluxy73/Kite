import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';

/// Parité hors-ligne des corrections serveur du playtest : tally de
/// sondage idempotent, garde-fous de dates, édition de type, texte vide
/// refusé. Mêmes règles que le serveur Go, même vocabulaire d'erreur.
void main() {
  late Directory tmp;
  late LocalStore s;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-parity-test');
    LocalStore.resetForTest();
    LocalStore.overridePathForTest('${tmp.path}/kite-local.json');
    s = await LocalStore.instance();
  });

  tearDown(() async {
    LocalStore.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Chat dm() => s.createChat('dm', 'Lucas', ['u-lucas']);

  test('(1) vote : tally incrémenté, idempotent par votant', () {
    final c = dm();
    final m = s.addMessage(c.id, 'u-lucas', 'poll', 'Choix ?', media: {
      'options': ['A', 'B'],
      'votes': <int>[0, 0],
      'voters': <String>[],
    });

    expect(s.votePoll(m.id, 'u-julien', 1), isTrue);
    expect((s.messageById(m.id)!.media!['votes'] as List)[1], 1);

    // Re-vote (même option ou autre) : pas de double comptage.
    expect(s.votePoll(m.id, 'u-julien', 1), isTrue);
    expect(s.votePoll(m.id, 'u-julien', 0), isTrue);
    expect(s.messageById(m.id)!.media!['votes'], [0, 1]);

    // Second votant : compte.
    expect(s.votePoll(m.id, 'u-lucas', 0), isTrue);
    expect(s.messageById(m.id)!.media!['votes'], [1, 1]);
  });

  test('(2) appel planifié dans le passé refusé', () {
    expect(
      () => s.addScheduledCall(
        meId: 'u-julien',
        title: 'Passé',
        scheduledAt: DateTime.now().millisecondsSinceEpoch - 1000,
      ),
      throwsArgumentError,
    );
    // Futur OK.
    expect(
      s.addScheduledCall(
        meId: 'u-julien',
        title: 'Futur',
        scheduledAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      ).title,
      'Futur',
    );
  });

  test('(2b) message programmé dans le passé refusé (parité serveur)', () {
    final c = dm();
    expect(
      () => s.addScheduledMessage(
        chatId: c.id,
        senderId: 'u-julien',
        text: 'trop tard',
        scheduledAt: 1000,
      ),
      throwsArgumentError,
    );
  });

  test('(3) édition : non-texte refusé, message étranger refusé, texte OK', () {
    final c = dm();
    final poll = s.addMessage(c.id, 'u-julien', 'poll', 'Q ?', media: {
      'options': ['A'],
      'votes': <int>[0],
      'voters': <String>[],
    });
    final text = s.addMessage(c.id, 'u-julien', 'text', 'salut');

    // Non-texte : refus (parité serveur, erreur honnête côté OfflineApi).
    expect(s.editMessage(poll.id, 'u-julien', 'hijack'), isFalse);
    // Message d'un autre : refus.
    final incoming = s.addMessage(c.id, 'u-lucas', 'text', 'coucou');
    expect(s.editMessage(incoming.id, 'u-julien', 'hijack'), isFalse);
    // Cas nominal : toujours OK.
    expect(s.editMessage(text.id, 'u-julien', 'modifié'), isTrue);
    expect(s.messageById(text.id)!.text, 'modifié');
  });

  test('(3b) OfflineApi.editMessage : erreurs honnêtes (introuvable/étranger/type)',
      () async {
    final c = dm();
    final poll = s.addMessage(c.id, 'u-julien', 'poll', 'Q ?', media: {
      'options': ['A'],
      'votes': <int>[0],
      'voters': <String>[],
    });
    final incoming = s.addMessage(c.id, 'u-lucas', 'text', 'coucou');
    final api = OfflineApi(meId: 'u-julien');
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    await expectLater(
      api.editMessage('m-ghost', 'x'),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('introuvable'))),
    );
    await expectLater(
      api.editMessage(incoming.id, 'x'),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('expéditeur'))),
    );
    await expectLater(
      api.editMessage(poll.id, 'x'),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('type de message'))),
    );
  });

  test('(4) OfflineApi.sendMessage : texte vide/blancs refusé, voice OK', () async {
    final c = dm();
    final api = OfflineApi(meId: 'u-julien');
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    await expectLater(api.sendMessage(c.id, text: ''),
        throwsArgumentError);
    await expectLater(api.sendMessage(c.id, text: '   '),
        throwsArgumentError);
    // Non-texte sans texte : valide (comme le serveur).
    await expectLater(
      api.sendMessage(c.id, type: 'voice', media: {'duration': 3}),
      completes,
    );
  });

  test('(5) logCall : attribue bien l appelant (message type=call)', () {
    final c = dm();
    s.logCall(c.id, 'u-lucas', kind: 'audio', direction: 'outgoing');
    final calls = s.messagesFor(c.id, 'u-lucas');
    final callMsg = calls.where((m) => m.type == 'call').last;
    expect(callMsg.senderId, 'u-lucas');
  });

  test('(6) deleteChat sur conversation inconnue : no-op silencieux sans erreur trompeuse',
      () {
    // Hors-ligne, il n'y a rien à supprimer : aucun état touché, aucune
    // erreur conflate « pas membre » — la vérité locale est le no-op.
    expect(() => s.deleteChatFor('c-ghost', 'u-julien'), returnsNormally);
  });
}
