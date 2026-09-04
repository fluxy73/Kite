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

  Widget gate(LockGateMode mode, FakeBio bio, VoidCallback onDone) =>
      MaterialApp(
        home: Scaffold(
          body: LockGate(
            chatId: 'c-1',
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

  test('store : préférence biométrique persistée et rechargée', () {
    final store = ChatLockStore.instance;
    expect(store.biometricsEnabled, isFalse);
    store.setLock('c-1', '1234');
    store.setBiometricsEnabled(true);
    expect(store.biometricsEnabled, isTrue);
    // Survit à un « redémarrage » (même fichier, instance réinitialisée).
    final reloaded = ChatLockStore.instance;
    reloaded.resetForTest(file: lockFile);
    expect(reloaded.biometricsEnabled, isTrue);
    expect(reloaded.isLocked('c-1'), isTrue);
  });

  test('unlockBiometric : sans effet si la préférence est désactivée', () {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.unlockBiometric('c-1');
    expect(store.canOpen('c-1'), isFalse);
    store.setBiometricsEnabled(true);
    store.unlockBiometric('c-1');
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : invite biométrique automatique puis déverrouillage',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.setBiometricsEnabled(true);
    final bio = FakeBio();
    var done = false;
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () => done = true));
    await tester.pump();
    await tester.pump();
    expect(bio.promptCount, 1);
    expect(done, isTrue);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : biométrie refusée -> message + repli code PIN',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.setBiometricsEnabled(true);
    final bio = FakeBio(result: false);
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () {}));
    await tester.pump();
    await tester.pump();
    expect(bio.promptCount, 1);
    expect(find.text('Biométrie non reconnue — utilisez le code PIN'),
        findsOneWidget);
    // Le code PIN reste la solution de secours.
    await typePin(tester);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('porte : biométrie indisponible -> pad PIN direct',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setLock('c-1', '1234');
    store.lock('c-1');
    store.setBiometricsEnabled(true);
    final bio = FakeBio(available: false);
    await tester.pumpWidget(gate(LockGateMode.unlock, bio, () {}));
    await tester.pump();
    expect(bio.promptCount, 0);
    expect(find.text('1'), findsOneWidget);
    await typePin(tester);
    expect(store.canOpen('c-1'), isTrue);
  });

  testWidgets('pose du verrou : proposition « Plus tard » ne change rien',
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
    expect(store.biometricsEnabled, isFalse);
    expect(store.isLocked('c-1'), isTrue);
  });

  testWidgets('pose du verrou : « Activer » active la préférence',
      (tester) async {
    final store = ChatLockStore.instance;
    final bio = FakeBio();
    await tester.pumpWidget(gate(LockGateMode.setup, bio, () {}));
    await tester.pump();
    await typePin(tester, rounds: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();
    expect(store.biometricsEnabled, isTrue);
    expect(store.isLocked('c-1'), isTrue);
  });
}
