import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/drafts.dart';
import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel des nouveautés : favoris, archivage, brouillons —
/// via la vraie pile hors-ligne (LocalStore + OfflineApi, fichier temporaire).
void main() {
  late Directory tmp;
  late String dataPath;
  late OfflineApi api;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-features-');
    dataPath = '${tmp.path}${Platform.pathSeparator}kite-local.json';
    LocalStore.overridePathForTest(dataPath);
    LocalStore.resetForTest();
    api = OfflineApi();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
    LocalStore.resetForTest();
  });

  test('Favori : toggle → état + persistance sur disque', () async {
    final chats = await api.fetchChats();
    final chatId = chats.first.id;
    await api.sendMessage(chatId, text: 'star-me-1');
    final msgs = await api.fetchMessages(chatId);
    final mine = msgs.lastWhere((m) => m.text == 'star-me-1');

    expect(mine.starredFor('u-julien'), isFalse);
    final nowStarred = await api.toggleStar(mine.id);
    expect(nowStarred, isTrue);

    // Persisté : le fichier contient starredBy.
    final raw = File(dataPath).readAsStringSync();
    expect(raw.contains('starredBy'), isTrue);
    expect(raw.contains('u-julien'), isTrue);

    // Toggle arrière.
    final after = await api.toggleStar(mine.id);
    expect(after, isFalse);
  });

  test('Archivage : la discussion quitte la liste, entre dans Archivées', () async {
    final chats = await api.fetchChats();
    final dm = chats.firstWhere((c) => !c.isGroup);
    expect(dm.archivedFor('u-julien'), isFalse);

    await api.setChatArchived(dm.id, archived: true);

    final after = await api.fetchChats();
    expect(after.firstWhere((c) => c.id == dm.id).archivedFor('u-julien'), isTrue);

    // Persistance : nouveau store depuis le disque -> toujours archivée.
    LocalStore.resetForTest();
    final api2 = OfflineApi();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final reloaded = await api2.fetchChats();
    expect(reloaded.firstWhere((c) => c.id == dm.id).archivedFor('u-julien'), isTrue);

    // Désarchivage.
    await api2.setChatArchived(dm.id, archived: false);
    final restored = await api2.fetchChats();
    expect(restored.firstWhere((c) => c.id == dm.id).archivedFor('u-julien'), isFalse);
  });

  test('Brouillon : save/clear et rechargement depuis le disque', () async {
    final tmpDraft =
        '${tmp.path}${Platform.pathSeparator}kite-drafts.json';
    DraftStore.instance.resetForTest(file: File(tmpDraft));

    // Premier « process » : écrit un brouillon.
    DraftStore.instance.save('c-lucas', 'brouillon-en-cours-42');
    DraftStore.instance.flushIfNeeded();

    // Second « process » : recharge depuis le disque.
    DraftStore.instance.resetForTest(file: File(tmpDraft));
    expect(DraftStore.instance.load('c-lucas'), 'brouillon-en-cours-42');
    // Les autres conversations n'ont pas de brouillon.
    expect(DraftStore.instance.load('c-emma'), '');

    // clear supprime et persiste la suppression.
    DraftStore.instance.clear('c-lucas');
    DraftStore.instance.resetForTest(file: File(tmpDraft));
    expect(DraftStore.instance.load('c-lucas'), '');
  });
}
