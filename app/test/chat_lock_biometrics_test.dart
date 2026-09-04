import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/chat_lock.dart';

/// Authentificateur factice : pas de canal de plateforme, compteur
/// d'invites et résultat contrôlé.
class FakeBio implements BiometricAuthenticator {
  FakeBio({this.available = true, this.result = true});
  bool available;
  bool result;
  int promptCount = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    promptCount++;
    return result;
  }
}

void main() {
  late Directory tmp;
  late File lockFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-bio-test');
    lockFile = File('${tmp.path}/lock.json');
    ChatLockStore.instance.resetForTest(file: lockFile);
  });

  tearDown(() async {
    ChatLockStore.instance.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Widget gate(LockGateMode mode, FakeBio bio, VoidCallback onDone,
          {String chatId = 'c-1'}) =>
      MaterialApp(
        home: Scaffold(
          body: LockGate(
            chatId: chatId,
            chatName: 'Lucas',
            mode: mode,
            onDone: onDone,
            authenticator: bio,
          ),
        ),
      );

  Future<void> typePin(WidgetTester tester, {int rounds = 1}) async {
    for (var r = 0; r < rounds; r++) {
      for (final d in ['1', '2', '3', '4']) {
        await tester.tap(find.text(d));
        await tester.pump();
      }
    }
  }

  test('préférence par conversation : indépendante et persistée', () {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.setLock('c-2', '5678');
    expect(store.biometricsFor('c-1'), isFalse);
    expect(store.biometricsFor('c-2'), isFalse);

    store.setBiometricsFor('c-1', true);
    expect(store.biometricsFor('c-1'), isTrue);
    expect(store.biometricsFor('c-2'), isFalse); // l'autre ne bouge pas

    // Survit à un « redémarrage » (même fichier, instance réinitialisée).
    final reloaded = ChatLockStore.instance;
    reloaded.resetForTest(file: lockFile);
    expect(reloaded.biometricsFor('c-1'), isTrue);
    expect(reloaded.biometricsFor('c-2'), isFalse);
    expect(reloaded.isLocked('c-1'), isTrue);
  });

  test('setBiometricsFor : sans effet sans verrou', () {
    final store = ChatLockStore.instance;
    store.setBiometricsFor('c-inconnu', true);
    expect(store.biometricsFor('c-inconnu'), isFalse);
  });

  test('migration : ancien réglage global appliqué à tous les verrous', () {
    // Fichier écrit par l'ancienne version : clé '_biometrics' globale.
    lockFile.writeAsStringSync(jsonEncode({
      'c-1': {'hash': 'h1'},
      'c-2': {'hash': 'h2'},
      '_biometrics': true,
    }));
    final store = ChatLockStore.instance;
    store.resetForTest(file: lockFile);
    expect(store.biometricsFor('c-1'), isTrue);
    expect(store.biometricsFor('c-2'), isTrue);
  });

  test('removeLock retire aussi la préférence biométrique', () {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.setBiometricsFor('c-1', true);
    store.removeLock('c-1', '1234');
    expect(store.isLocked('c-1'), isFalse);
    // Re-posé plus tard : biométrie non restaurée.
    store.setLock('c-1', '1234');
    expect(store.biometricsFor('c-1'), isFalse);
  });

  test('unlockBiometric : sans effet si la conversation est désactivée', () {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.setLock('c-2', '5678');
    store.lock('c-1');
    store.lock('c-2');
    store.setBiometricsFor('c-1', true); // seulement c-1
    store.unlockBiometric('c-2'); // ignoré
    expect(store.canOpen('c-2'), isFalse);
    store.unlockBiometric('c-1');
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : invite biométrique auto si activée pour CE chat',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.setLock('c-2', '5678');
    store.setBiometricsFor('c-1', true);
    final bio = FakeBio();
    var done = false;
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () => done = true));
    await tester.pump();
    await tester.pump();
    expect(bio.promptCount, 1);
    expect(done, isTrue);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : pas d\'invite si CE chat n\'a pas la biométrie',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.setLock('c-2', '5678');
    store.setBiometricsFor('c-2', true); // autre conversation
    final bio = FakeBio();
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () {}));
    await tester.pump();
    await tester.pump();
    expect(bio.promptCount, 0); // c-1 : pad PIN direct
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('porte : biométrie refusée -> message + repli code PIN',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.setBiometricsFor('c-1', true);
    final bio = FakeBio(result: false);
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () {}));
    await tester.pump();
    await tester.pump();
    expect(bio.promptCount, 1);
    expect(find.text('Biométrie non reconnue — utilisez le code PIN'),
        findsOneWidget);
    await typePin(tester);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : biométrie indisponible -> pad PIN direct',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.setBiometricsFor('c-1', true);
    final bio = FakeBio(available: false);
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () {}));
    await tester.pump();
    expect(bio.promptCount, 0);
    expect(find.text('1'), findsOneWidget);
    await typePin(tester);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('pose du verrou : « Plus tard » ne change rien',
      (tester) async {
    final store = ChatLockStore.instance;
    final bio = FakeBio();
    await tester.pumpWidget(gate(LockGateMode.setup, bio, () {}));
    await tester.pump();
    await typePin(tester, rounds: 2);
    await tester.pumpAndSettle();
    expect(find.text('Déverrouillage biométrique'), findsOneWidget);
    await tester.tap(find.text('Plus tard'));
    await tester.pumpAndSettle();
    expect(store.biometricsFor('c-1'), isFalse);
    expect(store.isLocked('c-1'), isTrue);
  });

  testWidgets('pose du verrou : « Activer » active CE chat', (tester) async {
    final store = ChatLockStore.instance;
    final bio = FakeBio();
    await tester.pumpWidget(gate(LockGateMode.setup, bio, () {}));
    await tester.pump();
    await typePin(tester, rounds: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();
    expect(store.biometricsFor('c-1'), isTrue);
    expect(store.isLocked('c-1'), isTrue);
  });
}
