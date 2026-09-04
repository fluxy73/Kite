import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel de la pile hors-ligne (LocalStore + OfflineApi) :
/// activer le minuteur -> horodatage des nouveaux messages -> disparition
/// au sweep -> persistance -> désactivation. Aucun serveur.
void main() {
  late Directory tmp;
  setUp(() {
    LocalStore.resetForTest();
    tmp = Directory.systemTemp.createTempSync('kite-dm-test');
    LocalStore.overridePathForTest('${tmp.path}/state.json');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<OfflineApi> ready() async {
    final api = OfflineApi();
    for (var i = 0; i < 100 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return api;
  }

  test('offline: timer on -> message stamped -> gone after expiry -> system message visible', () async {
    final api = await ready();
    expect(api.ready, isTrue);

    // ---- 1. Activation du minuteur (24 h raccourci n'est pas possible :
    // ---- les durées sont fixées, on teste le sweep via expiry passe) ----
    // Le minuteur n'accepte que 24h/7j/90j : pour tester la disparition on
    // écrit un message avec expiresAt dans le passé.
    await api.setChatDisappearing('c-lucas', 24 * 3600 * 1000);

    final shell = await api.fetchAppShell();
    final chat = shell.chats.firstWhere((c) => c.id == 'c-lucas');
    expect(chat.disappearing, 24 * 3600 * 1000);

    // Message système + horodatage éphémère sur un nouveau message.
    final msgs = await api.fetchMessages('c-lucas');
    final sys = msgs.where((m) => m.type == 'system').toList();
    expect(sys, isNotEmpty,
        reason: 'le message système du minuteur doit être visible');
    expect(sys.last.text, contains('24 h'));

    final sent = await api.sendMessage('c-lucas', text: 'éphémère test');
    expect(sent.expiresAt, isNotNull,
        reason: 'un message envoyé avec minuteur actif porte expiresAt');
    final sentSys = msgs.where((m) => m.type == 'system');
    expect(sentSys, isNotEmpty);

    // ---- 2. Disparition : écriture directe d'un expiresAt passé ----
    final store = await LocalStore.instance();
    final expired = sent.copyWith(
      expiresAt: DateTime.now().millisecondsSinceEpoch - 1000,
    );
    store.upsertMessage(expired);
    final swept = store.expireSweep();
    expect(swept['c-lucas'], contains(sent.id));

    // Plus visible après le sweep.
    final after = await api.fetchMessages('c-lucas');
    expect(after.any((m) => m.id == sent.id), isFalse,
        reason: 'le message échu disparaît de la conversation');

    // ---- 3. Désactivation ----
    await api.setChatDisappearing('c-lucas', 0);
    final shell2 = await api.fetchAppShell();
    expect(
      shell2.chats.firstWhere((c) => c.id == 'c-lucas').disappearing,
      0,
    );
    // Le message de désactivation est bien un système.
    final msgs2 = await api.fetchMessages('c-lucas');
    expect(msgs2.any((m) => m.type == 'system' && m.text.contains('désactivés')), isTrue);
  });

  test('offline: disappearing setting + messages survive app restart', () async {
    final api = await ready();
    await api.setChatDisappearing('c-emma', 7 * 24 * 3600 * 1000);
    final sent = await api.sendMessage('c-emma', text: 'survive-restart');

    // "Redémarrage" : nouvelles instances, même fichier.
    final store = await LocalStore.instance();
    LocalStore.resetForTest();
    final store2 = await LocalStore.instance();
    expect(store2, isNot(same(store)));
    final api2 = OfflineApi();
    for (var i = 0; i < 100 && !api2.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final shell = await api2.fetchAppShell();
    expect(
      shell.chats.firstWhere((c) => c.id == 'c-emma').disappearing,
      7 * 24 * 3600 * 1000,
      reason: 'le réglage survit au redémarrage',
    );
    final msgs = await api2.fetchMessages('c-emma');
    expect(msgs.any((m) => m.id == sent.id), isTrue,
        reason: 'le message éphémère non échu survit au redémarrage');
  });

  test('offline: messages without timer are never stamped', () async {
    final api = await ready();
    final sent = await api.sendMessage('c-lucas', text: 'normal-msg');
    expect(sent.expiresAt, isNull);
  });
}
