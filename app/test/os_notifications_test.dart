import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/message_notifier.dart';
import 'package:kite/models.dart';
import 'package:kite/offline_api.dart';
import 'package:kite/os_notifications.dart';

/// Comportement du routage des notifications (OS vs in-app) et de la
/// suppression des bannières, sans plugin natif : le hook OS est injecté
/// (fake) et OsNotifications est testé à travers son état `available`.
void main() {
  late Directory tmp;
  late String dataPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-os-notif-test');
    dataPath = '${tmp.path}${Platform.pathSeparator}kite-data.json';
    LocalStore.overridePathForTest(dataPath);
    LocalStore.resetForTest();
    // Le service OS est hors jeu dans les tests (pas d'init plugin) :
    // disponible=false partout.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {
    MessageNotifier.instance.stop();
    MessageNotifier.instance.osShow = null;
    await tmp.delete(recursive: true);
  });

  ServerEvent msgEvent(String chatId, String senderId, String text) {
    return ServerEvent('message', {
      'id': 'm-os-${DateTime.now().microsecondsSinceEpoch}-$senderId',
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

  test('OsNotifications sans init : unavailable et no-op', () async {
    // Pas d'init() : available=false, show/cancel sont des no-op sûrs.
    final os = OsNotifications.instance;
    expect(os.available, isFalse);
    // Ne doit pas lever.
    await os.show(const MessageNotification(
      chatId: 'c-lucas',
      chatName: 'Lucas Martin',
      message: Message(
        id: 'm1',
        chatId: 'c-lucas',
        senderId: 'u-lucas',
        type: 'text',
        text: 'hello',
        createdAt: 0,
      ),
    ));
    await os.cancelForChat('c-lucas');
  });

  test('le notifier route en arrière-plan vers le hook OS (fake)',
      () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final notifier = MessageNotifier.instance;
    notifier.start(api, meId: api.meId);

    final osShown = <MessageNotification>[];
    notifier.osShow = (n) async => osShown.add(n);

    // Simule l'app en arrière-plan.
    // (lifecycleState = null en test, != resumed → voie OS)
    await notifier.handleEvent(msgEvent('c-lucas', 'u-lucas', 'en fond'));
    expect(osShown, hasLength(1));
    expect(osShown.first.chatId, 'c-lucas');
    expect(notifier.last.value, isNull); // pas de snackbar en fond

    // Retour au premier plan : snackbar in-app, pas d'OS.
    notifier.osShow = null;
    notifier.last.addListener(() {}); // keep listener-free semantics simple
    await notifier.handleEvent(msgEvent('c-lucas', 'u-lucas', 'au premier'));
    expect(osShown, hasLength(1)); // inchangé
    expect(notifier.last.value, isNotNull);
    expect(notifier.last.value!.body, 'au premier');
    notifier.reset();
  });

  test('sourdine : ni OS ni in-app, même en arrière-plan', () async {
    final api = OfflineApi();
    for (var i = 0; i < 50 && !api.ready; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final notifier = MessageNotifier.instance;
    notifier.start(api, meId: api.meId);

    final osShown = <MessageNotification>[];
    notifier.osShow = (n) async => osShown.add(n);

    await api.setChatMuted('c-emma', duration: '8h');
    await notifier.handleEvent(msgEvent('c-emma', 'u-emma', 'muette'));
    expect(osShown, isEmpty);
    expect(notifier.last.value, isNull);

    await api.setChatMuted('c-emma', duration: 'off');
    await notifier.handleEvent(msgEvent('c-emma', 'u-emma', 'démute'));
    expect(osShown, hasLength(1));
    notifier.osShow = null;
  });
}
