import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel : épinglage persistant + suppression « pour moi »
/// (renaissance à l'arrivée d'un nouveau message) — via la vraie pile
/// hors-ligne (LocalStore + OfflineApi, fichier temporaire).
void main() {
  late Directory tmp;
  late String dataPath;
  late OfflineApi api;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-pin-');
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

  test('Épinglage : état + persistance sur disque + tri en tête de liste',
      () async {
    final chats = await api.fetchChats();
    final dm = chats.firstWhere((c) => !c.isGroup);
    expect(dm.pinnedFor('u-julien'), isFalse);

    await api.setChatPinned(dm.id, pinned: true);

    final after = await api.fetchChats();
    expect(after.firstWhere((c) => c.id == dm.id).pinnedFor('u-julien'), isTrue);
    // Le fichier contient l'épinglage.
    final raw = File(dataPath).readAsStringSync();
    expect(raw.contains('pinned'), isTrue);

    // Détacher.
    await api.setChatPinned(dm.id, pinned: false);
    final off = await api.fetchChats();
    expect(
        off.firstWhere((c) => c.id == dm.id).pinnedFor('u-julien'), isFalse);
  });

  test('Suppression pour moi : invisible pour moi, visible pour l’autre',
      () async {
    final chats = await api.fetchChats();
    final dm = chats.firstWhere((c) => !c.isGroup);

    await api.deleteChat(dm.id);

    // Côté julien (celui qui a supprimé) : la discussion a disparu.
    final mine = await api.fetchChats();
    expect(mine.where((c) => c.id == dm.id), isEmpty);

    // Côté lucas (l'autre membre) : la discussion est toujours là.
    final otherApi = OfflineApi(meId: 'u-lucas');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final theirs = await otherApi.fetchChats();
    expect(theirs.where((c) => c.id == dm.id), isNotEmpty);
  });

  test('Renaissance : un nouveau message ramène la discussion supprimée',
      () async {
    final chats = await api.fetchChats();
    final dm = chats.firstWhere((c) => !c.isGroup);
    await api.deleteChat(dm.id);
    expect((await api.fetchChats()).where((c) => c.id == dm.id), isEmpty);

    // L'autre membre écrit → la discussion renaît côté julien.
    final otherApi = OfflineApi(meId: 'u-lucas');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await otherApi.sendMessage(dm.id, text: 'tu es là ?');

    final revived = await api.fetchChats();
    expect(revived.where((c) => c.id == dm.id), isNotEmpty);
    // Et le message est lisible.
    final msgs = await api.fetchMessages(dm.id);
    expect(msgs.any((m) => m.text == 'tu es là ?'), isTrue);
  });

  test('Redémarrage : suppression et épinglage survivent au redémarrage',
      () async {
    final chats = await api.fetchChats();
    final dm = chats.firstWhere((c) => !c.isGroup);
    final group = chats.firstWhere((c) => c.isGroup);

    await api.deleteChat(dm.id);
    await api.setChatPinned(group.id, pinned: true);

    // Simule un redémarrage : nouvelles instances, même fichier.
    LocalStore.resetForTest();
    final api2 = OfflineApi();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final after = await api2.fetchChats();
    expect(after.where((c) => c.id == dm.id), isEmpty); // toujours supprimée
    expect(
        after.firstWhere((c) => c.id == group.id).pinnedFor('u-julien'),
        isTrue); // toujours épinglée
  });
}
