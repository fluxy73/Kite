import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel de la pile hors-ligne (LocalStore + OfflineApi) :
/// programmation -> persistance -> livraison automatique en message réel ->
/// annulation. Aucun serveur.
void main() {
  setUp(() {
    LocalStore.resetForTest();
  });

  test('offline: schedule -> not delivered early -> delivered at due time -> persisted', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.ready, isTrue);

    final now = DateTime.now().millisecondsSinceEpoch;
    // Marqueur unique : le fichier de données persiste entre les runs.
    final marker = 'anniv-$now';

    // ---- 1. Programmation ----
    final sm = await api.scheduleMessage(
      'c-lucas',
      text: marker,
      scheduledAt: now + 7000, // dans 7 s
    );
    expect(sm.chatId, 'c-lucas');
    expect(sm.senderId, 'u-julien');

    // Le shell la transporte ; elle n'est PAS encore dans la conversation.
    final shell = await api.fetchAppShell();
    expect(shell.scheduledMessages.map((s) => s.id), contains(sm.id));
    expect(
      (await api.fetchMessages('c-lucas')).any((m) => m.text == marker),
      isFalse,
      reason: 'le message ne doit pas partir avant l\'échéance',
    );

    // ---- 2. Annulation d'une seconde programmation ----
    final sm2 = await api.scheduleMessage(
      'c-lucas',
      text: 'a-annuler',
      scheduledAt: now + 999000,
    );
    await api.deleteScheduledMessage(sm2.id);
    expect(
      (await api.fetchScheduledMessages()).map((s) => s.id),
      isNot(contains(sm2.id)),
    );

    // ---- 3. Livraison automatique à l'échéance (ticker 5 s, marge 12 s) ----
    final delivered = await waitForMessage(
      api,
      (m) => m.text == marker && m.senderId == 'u-julien',
      timeout: const Duration(seconds: 20),
    );
    expect(delivered, isTrue);

    // Plus aucun message programmé en attente pour celui-là.
    expect(
      (await api.fetchScheduledMessages()).map((s) => s.id),
      isNot(contains(sm.id)),
    );
  });

  test('offline: scheduled message survives app restart (persistence)', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    const text = 'persist-marker';
    final sm = await api.scheduleMessage(
      'c-emma',
      text: text,
      scheduledAt: now + 3600 * 1000,
    );

    // "Redémarrage" : nouvelle instance, mêmes données persistées.
    LocalStore.resetForTest();
    final api2 = OfflineApi();
    for (var i = 0; i < 50 && !api2.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final list = await api2.fetchScheduledMessages();
    expect(list.map((s) => s.id), contains(sm.id));
    expect(list.map((s) => s.text), contains(text));
  });
}

/// Attend qu'un message satisfaisant [pred] apparaisse dans la conversation.
Future<bool> waitForMessage(
  OfflineApi api,
  bool Function(dynamic m) pred, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final msgs = await api.fetchMessages('c-lucas');
    if (msgs.any(pred)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return false;
}
