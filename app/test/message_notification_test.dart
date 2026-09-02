import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/message_notifier.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel de la pile de notifications : OfflineApi (store local
/// réel, fichier temporaire) + MessageNotifier. Vérifie la règle demandée :
/// conversation muette -> aucune notification ; sinon notification.
void main() {
  late Directory tmp;
  late String dataPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-notif-test');
    dataPath = '${tmp.path}${Platform.pathSeparator}kite-data.json';
    LocalStore.overridePathForTest(dataPath);
    LocalStore.resetForTest();
  });

  tearDown(() async {
    MessageNotifier.instance.stop();
    await tmp.delete(recursive: true);
  });

  ServerEvent msgEvent(String chatId, String senderId, String text) {
    // Même forme que les events serveur (Message.fromJson doit le parser).
    return ServerEvent('message', {
      'id': 'm-notif-${DateTime.now().microsecondsSinceEpoch}-$senderId',
      'chatId': chatId,
      'senderId': senderId,
      'type': 'text',
      'text': text,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'reactions': <String, dynamic>{},
      'readBy': <String>[],
      'deliveredTo': <String>[],
    });
  }

  Future<OfflineApi> newApi() async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return api;
  }

  /// Sonde [condition] jusqu'à succès ou timeout (le echo local met ~3 s).
  Future<T?> waitFor<T>(Future<T?> Function() condition,
      {required Duration timeout, required String label}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final r = await condition();
      if (r != null) return r;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timeout: $label');
  }

  group('filtres de MessageNotifier', () {
    late OfflineApi api;

    setUp(() async {
      api = await newApi();
      MessageNotifier.instance.start(api, meId: api.meId);
    });

    test('conversation muette : aucune notification', () async {
      await api.setChatMuted('c-lucas', duration: '8h');
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-lucas', 'u-lucas', 'salut (muet)'));
      expect(MessageNotifier.instance.last.value, isNull);
      await api.setChatMuted('c-lucas', duration: 'off');
    });

    test('conversation non muette : notification émise', () async {
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-lucas', 'u-lucas', 'salut'));
      final n = MessageNotifier.instance.last.value;
      expect(n, isNotNull);
      expect(n!.chatId, 'c-lucas');
      expect(n.body, 'salut');
      expect(n.senderName, isNotEmpty);
      MessageNotifier.instance.reset();
      expect(MessageNotifier.instance.last.value, isNull);
    });

    test('démute : les notifications repartent', () async {
      await api.setChatMuted('c-emma', duration: '8h');
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-emma', 'u-emma', 'pendant sourdine'));
      expect(MessageNotifier.instance.last.value, isNull);

      await api.setChatMuted('c-emma', duration: 'off');
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-emma', 'u-emma', 'après démute'));
      expect(MessageNotifier.instance.last.value, isNotNull);
      MessageNotifier.instance.reset();
    });

    test('mon propre message : aucune notification', () async {
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-lucas', 'u-julien', 'c’est moi'));
      expect(MessageNotifier.instance.last.value, isNull);
    });

    test('conversation ouverte à l’écran : aucune notification', () async {
      MessageNotifier.instance.openChat('c-emma');
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-emma', 'u-emma', 'écran ouvert'));
      expect(MessageNotifier.instance.last.value, isNull);
      MessageNotifier.instance.closeChat('c-emma');
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-emma', 'u-emma', 'écran fermé'));
      expect(MessageNotifier.instance.last.value, isNotNull);
      MessageNotifier.instance.reset();
    });

    test('chat inconnu : ignoré sans crash', () async {
      await MessageNotifier.instance
          .handleEvent(msgEvent('c-ghost', 'u-emma', '???'));
      expect(MessageNotifier.instance.last.value, isNull);
    });
  });

  test('bout en bout hors-ligne : écho simulé notifié, muet silencieux',
      () async {
    final api = await newApi();
    MessageNotifier.instance.start(api, meId: api.meId);

    // 1. Chat non muet : l'écho simulé (3 s) déclenche une notification.
    await api.sendMessage('c-lucas', text: 'ping-notif');
    final n = await waitFor(
      () async => MessageNotifier.instance.last.value,
      timeout: const Duration(seconds: 10),
      label: 'notification écho',
    );
    expect(n, isNotNull);
    expect(n!.chatId, 'c-lucas');
    MessageNotifier.instance.reset();

    // 2. Chat muet : aucun écho notifié pendant la sourdine.
    await api.setChatMuted('c-lucas', duration: 'always');
    await api.sendMessage('c-lucas', text: 'ping-muet');
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(MessageNotifier.instance.last.value, isNull);

    api.dispose();
  });
}
