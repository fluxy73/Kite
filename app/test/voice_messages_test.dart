import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';

/// Cycle de vie réel du vocal : envoi avec chemin de fichier -> persistance
/// locale -> relecture après « redémarrage » (nouvelles instances, même
/// fichier de données, aucun serveur). Le chemin stocké doit pointer vers
/// un fichier existant pour que la lecture réelle fonctionne.
void main() {
  late Directory tmp;
  late File storeFile;
  late String voicePath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-voice-test');
    storeFile = File('${tmp.path}${Platform.pathSeparator}kite-store.json');
    LocalStore.overridePathForTest(storeFile.path);
    // Un faux fichier audio « enregistré » (assez grand pour passer le seuil).
    voicePath = '${tmp.path}${Platform.pathSeparator}voice-1.m4a';
    File(voicePath).writeAsBytesSync(List.filled(2048, 1));
  });

  tearDown(() async {
    // (pas de reset du chemin nécessaire : chaque setUp écrase la valeur)
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('envoi vocal avec fichier -> persisté -> rejouable après redémarrage',
      () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final shell = await api.fetchAppShell();
    final chatId = shell.chats.first.id;

    final sent = await api.sendMessage(chatId,
        type: 'voice', media: {'duration': 4, 'path': voicePath});
    expect((sent.media?['path'] as String?) ?? '', voicePath);
    expect(sent.media?['duration'], 4);

    // « Redémarrage » : nouvelles instances sur le même fichier.
    final api2 = OfflineApi();
    for (var i = 0; i < 50 && !api2.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final messages = await api2.fetchMessages(chatId);
    final voice = messages.where((m) => m.type == 'voice').toList();
    expect(voice, isNotEmpty);
    final restored = voice.last;
    expect(restored.media?['path'], voicePath);
    // Le fichier référencé existe réellement (condition de la lecture réelle).
    expect(File(restored.media!['path'] as String).existsSync(), isTrue);
  });

  test('vocal sans chemin (seed/simulé) : media parsé sans crash', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final shell = await api.fetchAppShell();
    final chatId = shell.chats.first.id;
    final sent = await api.sendMessage(chatId,
        type: 'voice', media: {'duration': 7});
    expect(sent.media?['path'], isNull);
    expect(sent.media?['duration'], 7);
  });
}
