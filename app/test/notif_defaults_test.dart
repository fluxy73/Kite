import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/message_notifier.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';

/// Défauts de notification globaux : chaîne de résolution (conversation >
/// global > intégré), persistance hors-ligne et intégration au notifier.
void main() {
  late Directory tmp;
  late String dataPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-notif-defaults-test');
    dataPath = '${tmp.path}${Platform.pathSeparator}kite-data.json';
    LocalStore.overridePathForTest(dataPath);
    LocalStore.resetForTest();
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {
    MessageNotifier.instance.stop();
    MessageNotifier.instance.osShow = null;
    MessageNotifier.instance.globalDefaults = const NotifPrefs();
    await tmp.delete(recursive: true);
  });

  ServerEvent msgEvent(String chatId, String senderId, String text) {
    return ServerEvent('message', {
      'id': 'm-gd-${DateTime.now().microsecondsSinceEpoch}-$senderId',
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

  test('resolveWith : conversation > global > intégré', () {
    // La conversation prime sur le global, le global sur l'intégré.
    final resolved = const NotifPrefs(priority: NotifPriority.high)
        .resolveWith(const NotifPrefs(sound: false));
    expect(resolved.priority, NotifPriority.high);
    expect(resolved.soundOn, isFalse);
    expect(resolved.previewOn, isTrue); // défaut intégré

    // Conversation sans réglage : le global s'applique.
    const empty = NotifPrefs();
    final fromGlobal = empty.resolveWith(const NotifPrefs(
      priority: NotifPriority.low,
      preview: false,
    ));
    expect(fromGlobal.priorityOrNormal, NotifPriority.low);
    expect(fromGlobal.previewOn, isFalse);
    expect(fromGlobal.soundOn, isTrue);

    // Rien de réglé nulle part : défauts de l'app.
    final appDefaults = empty.resolveWith(const NotifPrefs());
    expect(appDefaults.priorityOrNormal, NotifPriority.normal);
    expect(appDefaults.soundOn, isTrue);
    expect(appDefaults.previewOn, isTrue);
  });

  test('aller-retour hors-ligne + persistance au redémarrage', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    await api.setNotifDefaults(
      prefs: const NotifPrefs(priority: NotifPriority.high, sound: false),
    );
    var shell = await api.fetchAppShell();
    expect(shell.notifDefaults.priority, NotifPriority.high);
    expect(shell.notifDefaults.soundOn, isFalse);
    expect(shell.notifDefaults.previewOn, isTrue);

    // Le shell hors-ligne transporte bien les défauts (comme le serveur).
    expect(shell.notifDefaults.isEmpty, isFalse);

    // « Redémarrage » : nouvelles instances sur le même fichier.
    LocalStore.resetForTest();
    final api2 = OfflineApi();
    for (var i = 0; i < 50 && !api2.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    shell = await api2.fetchAppShell();
    expect(shell.notifDefaults.priority, NotifPriority.high);
    expect(shell.notifDefaults.soundOn, isFalse);

    // Remise aux défauts (null) : tout revient aux valeurs intégrées.
    await api2.setNotifDefaults();
    shell = await api2.fetchAppShell();
    expect(shell.notifDefaults.isEmpty, isTrue);
    expect(shell.notifDefaults.soundOn, isTrue);
    expect(shell.notifDefaults.priorityOrNormal, NotifPriority.normal);
  });

  test('le notifier applique global puis la priorité conversation', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Défauts globaux AVANT le démarrage : ils sont chargés depuis le shell.
    await api.setNotifDefaults(
      prefs: const NotifPrefs(sound: false, preview: false),
    );

    final notifier = MessageNotifier.instance;
    notifier.start(api, meId: api.meId);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifier.globalDefaults.soundOn, isFalse);

    // Conversation sans réglage propre : défauts globaux appliqués.
    await notifier.handleEvent(msgEvent('c-lucas', 'u-lucas', 'global'));
    var n = notifier.last.value;
    expect(n, isNotNull);
    expect(n!.soundOn, isFalse); // global
    expect(n.body, ''); // aperçu global désactivé → corps vide
    expect(n.priority, NotifPriority.normal); // intégré
    notifier.reset();

    // Override conversation : prime sur le global.
    await api.setChatNotifs('c-emma', prefs: const NotifPrefs(sound: true));
    await notifier.handleEvent(msgEvent('c-emma', 'u-emma', 'override'));
    n = notifier.last.value;
    expect(n, isNotNull);
    expect(n!.soundOn, isTrue); // réglage conversation
    expect(n.body, ''); // pas d'override aperçu → global toujours appliqué
  });
}
