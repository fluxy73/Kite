import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/message_notifier.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';

/// Comportement réel des préférences de notification par conversation :
/// store local réel (fichier temporaire, pas de serveur) + parsing JSON
/// serveur + intégration notificateur (aperçu masqué, priorité).
void main() {
  late Directory tmp;
  late String dataPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-notif-prefs-test');
    dataPath = '${tmp.path}${Platform.pathSeparator}kite-data.json';
    LocalStore.overridePathForTest(dataPath);
    LocalStore.resetForTest();
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {
    MessageNotifier.instance.stop();
    MessageNotifier.instance.osShow = null;
    await tmp.delete(recursive: true);
  });

  Future<OfflineApi> newApi() async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return api;
  }

  ServerEvent msgEvent(String chatId, String senderId, String text) {
    return ServerEvent('message', {
      'id': 'm-prefs-${DateTime.now().microsecondsSinceEpoch}-$senderId',
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

  test('round-trip offline + persistance au redémarrage', () async {
    final api = await newApi();

    await api.setChatNotifs('c-lucas',
        prefs: const NotifPrefs(
            priority: NotifPriority.high, sound: false, preview: false));
    final chats = await api.fetchChats();
    final prefs = chats.firstWhere((c) => c.id == 'c-lucas').notifsFor('u-julien');
    expect(prefs?.priority, NotifPriority.high);
    expect(prefs?.soundOn, isFalse);
    expect(prefs?.previewOn, isFalse);

    // « Redémarrage » : nouvelles instances, même fichier.
    LocalStore.resetForTest();
    final api2 = await newApi();
    final prefs2 =
        (await api2.fetchChats()).firstWhere((c) => c.id == 'c-lucas').notifsFor('u-julien');
    expect(prefs2?.priority, NotifPriority.high);
    expect(prefs2?.soundOn, isFalse);

    // Remise aux défauts (prefs vide/absent) : entrée supprimée.
    await api2.setChatNotifs('c-lucas');
    final after =
        (await api2.fetchChats()).firstWhere((c) => c.id == 'c-lucas').notifsFor('u-julien');
    expect(after, isNull);
  });

  test('parsing du JSON serveur (string priority, bools optionnels)', () {
    final chat = Chat.fromJson({
      'id': 'c-x',
      'type': 'dm',
      'name': 'X',
      'memberIds': ['u-julien', 'u-emma'],
      'notifs': {
        'u-emma': {'priority': 'high', 'preview': false},
        'u-thomas': {'priority': 'default', 'sound': true},
      },
    });
    final p = chat.notifsFor('u-emma');
    expect(p?.priority, NotifPriority.high);
    expect(p?.previewOn, isFalse);
    expect(p?.soundOn, isTrue); // défaut effectif
    // 'default' -> NotifPriority.normal, son effectif true.
    final t = chat.notifsFor('u-thomas');
    expect(t?.priority, NotifPriority.normal);
    expect(t?.soundOn, isTrue);
    // Sans prefs : null, valeurs effectives par défaut.
    expect(chat.notifsFor('u-julien'), isNull);
  });

  test('aperçu masqué : le corps notifié ne contient jamais le texte',
      () async {
    final api = await newApi();
    final notifier = MessageNotifier.instance;
    notifier.start(api, meId: api.meId);

    await api.setChatNotifs('c-lucas', prefs: const NotifPrefs(preview: false));
    await notifier.handleEvent(msgEvent('c-lucas', 'u-lucas', 'secret très privé'));
    final n = notifier.last.value;
    expect(n, isNotNull);
    expect(n!.body, ''); // corps vide, pas de texte
    expect(n.body, isNot(contains('secret')));
    notifier.reset();

    // Aperçu réactivé : le texte revient.
    await api.setChatNotifs('c-lucas', prefs: const NotifPrefs(preview: true));
    await notifier.handleEvent(msgEvent('c-lucas', 'u-lucas', 'texte visible'));
    expect(notifier.last.value!.body, 'texte visible');
    notifier.reset();
  });

  test('priorité propagée dans la notification', () async {
    final api = await newApi();
    final notifier = MessageNotifier.instance;
    notifier.start(api, meId: api.meId);

    await api.setChatNotifs('c-emma', prefs: const NotifPrefs(priority: NotifPriority.low));
    await notifier.handleEvent(msgEvent('c-emma', 'u-emma', 'priorité basse'));
    expect(notifier.last.value!.priority, NotifPriority.low);
    notifier.reset();
  });

  test('suppression de la conversation : réglages personnels nettoyés',
      () async {
    final api = await newApi();
    // Réglages pour julien ET lucas (mêmes membres sur les chats seedés).
    await api.setChatNotifs('c-lucas',
        prefs: const NotifPrefs(priority: NotifPriority.high));
    final store = await LocalStore.instance();
    store.setNotifs('c-lucas', 'u-lucas', const NotifPrefs(preview: false));
    expect(store.chats.firstWhere((c) => c.id == 'c-lucas').notifs, hasLength(2));

    // Julien supprime la discussion : ses réglages partent, ceux de lucas restent.
    api.deleteChat('c-lucas');
    final chat = store.chats.firstWhere((c) => c.id == 'c-lucas');
    expect(chat.notifsFor('u-julien'), isNull);
    expect(chat.notifsFor('u-lucas'), isNotNull);
    // Parité : la sourdine personnelle suit la même règle.
    expect(chat.mutedFor('u-julien'), isFalse);
  });
}
