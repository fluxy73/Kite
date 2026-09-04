import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';

/// Dossiers façon Telegram : CRUD via OfflineApi (LocalStore miroir),
/// filtrage de la liste, appartenance multiple, persistance sur disque.
void main() {
  late Directory tmp;
  late String storePath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-folders-test');
    storePath = '${tmp.path}/kite-local.json';
    LocalStore.resetForTest();
    LocalStore.overridePathForTest(storePath);
  });

  tearDown(() async {
    LocalStore.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<OfflineApi> readyApi() async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.ready, isTrue);
    return api;
  }

  test('CRUD dossiers + appartenance multiple + filtrage', () async {
    final api = await readyApi();
    final shell = await api.fetchAppShell();
    final chatA = shell.chats.first.id;
    final chatB = shell.chats[1].id;

    // Création.
    final f = await api.createFolder('Travail');
    expect(f.name, 'Travail');
    expect(f.chatIds, isEmpty);

    // Ajout de deux conversations au même dossier.
    await api.folderMembership(f.id, chatA, add: true);
    await api.folderMembership(f.id, chatB, add: true);
    var folders = await api.fetchFolders();
    expect(folders, hasLength(1));
    expect(folders.first.chatIds, containsAll([chatA, chatB]));

    // Une conversation peut appartenir à plusieurs dossiers.
    final f2 = await api.createFolder('Perso');
    await api.folderMembership(f2.id, chatA, add: true);
    folders = await api.fetchFolders();
    expect(
        folders.where((x) => x.chatIds.contains(chatA)).length, 2);

    // Retrait.
    await api.folderMembership(f.id, chatB, add: false);
    folders = await api.fetchFolders();
    expect(folders.firstWhere((x) => x.id == f.id).chatIds, [chatA]);

    // Renommage.
    await api.renameFolder(f.id, 'Boulot');
    folders = await api.fetchFolders();
    expect(folders.firstWhere((x) => x.id == f.id).name, 'Boulot');

    // Suppression : les conversations ne sont pas touchées.
    final chatCount = (await api.fetchAppShell()).chats.length;
    await api.deleteFolder(f.id);
    folders = await api.fetchFolders();
    expect(folders.any((x) => x.id == f.id), isFalse);
    expect((await api.fetchAppShell()).chats.length, chatCount);
  });

  test('persisté sur disque à travers un redémarrage', () async {
    final api = await readyApi();
    final shell = await api.fetchAppShell();
    final chat = shell.chats.first.id;
    final f = await api.createFolder('Famille');
    await api.folderMembership(f.id, chat, add: true);

    // "Redémarrage" : nouvelles instances, même fichier.
    LocalStore.resetForTest();
    final api2 = await readyApi();
    final folders = await api2.fetchFolders();
    expect(folders, hasLength(1));
    expect(folders.first.name, 'Famille');
    expect(folders.first.chatIds, [chat]);
  });

  test('filtrage par dossier dans le shell', () async {
    final api = await readyApi();
    final shell = await api.fetchAppShell();
    final inFolder = shell.chats.first.id;
    final f = await api.createFolder('Proches');
    await api.folderMembership(f.id, inFolder, add: true);

    final folders = await api.fetchFolders();
    final active = folders.first;
    final visible =
        shell.chats.where((c) => active.chatIds.contains(c.id)).toList();
    expect(visible.map((c) => c.id), [inFolder]);
    // Les autres discussions restent accessibles via « Toutes ».
    expect(shell.chats.length, greaterThan(visible.length));
  });
}
