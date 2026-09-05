import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/chat_lock.dart';

/// Authentificateur factice : compteur d'invites, résultat contrôlé.
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

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kite-applock-test');
    lockFile = File('${tmp.path}/lock.json');
    ChatLockStore.instance.resetForTest(file: lockFile);
  });

  tearDown(() {
    ChatLockStore.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> typeCode(WidgetTester tester, String code) async {
    for (final d in code.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pump();
  }

  test('setAppLock : code invalide refuse, double pose refusee', () {
    final store = ChatLockStore.instance;
    expect(store.appLockEnabled, isFalse);
    expect(store.setAppLock('12'), isFalse);
    expect(store.setAppLock('abcd'), isFalse);
    expect(store.setAppLock('1234'), isTrue);
    expect(store.appLockEnabled, isTrue);
    expect(store.setAppLock('9999'), isFalse);
  });

  test('unlockApp : mauvais code refuse, bon code accepte', () {
    final store = ChatLockStore.instance;
    store.setAppLock('4321');
    expect(store.unlockApp('0000'), isFalse);
    expect(store.unlockApp('4321'), isTrue);
  });

  test('removeAppLock : code requis, reinitialise la biometrie', () {
    final store = ChatLockStore.instance;
    store.setAppLock('1234');
    store.setAppBiometrics(true);
    expect(store.removeAppLock('9999'), isFalse);
    expect(store.appLockEnabled, isTrue);
    expect(store.removeAppLock('1234'), isTrue);
    expect(store.appLockEnabled, isFalse);
    expect(store.appBiometricsEnabled, isFalse);
  });

  test('persistence : le verrou et la biometrie survivent au redemarrage',
      () {
    final store = ChatLockStore.instance;
    store.setAppLock('2468');
    store.setAppBiometrics(true);

    // Nouvelle instance sur le MEME fichier = redemarrage.
    ChatLockStore.instance.resetForTest(file: lockFile);
    final store2 = ChatLockStore.instance;
    expect(store2.appLockEnabled, isTrue);
    expect(store2.appBiometricsEnabled, isTrue);
    expect(store2.unlockApp('2468'), isTrue);
    expect(store2.unlockApp('1357'), isFalse);
  });

  testWidgets('porte setup : code + confirmation + offre biometrique',
      (tester) async {
    final bio = FakeBio(available: true);
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppLockGate(
          mode: AppLockGateMode.setup,
          onDone: () => done = true,
          authenticator: bio,
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Choisissez un code à 4 chiffres'), findsOneWidget);
    await typeCode(tester, '1234');
    await tester.pump();
    expect(find.text('Confirmez le code'), findsOneWidget);
    await typeCode(tester, '1234');
    await tester.pumpAndSettle();

    // Offre d'activation biométrique affichée -> Activer.
    expect(find.text('Déverrouillage biométrique'), findsOneWidget);
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(ChatLockStore.instance.appLockEnabled, isTrue);
    expect(ChatLockStore.instance.appBiometricsEnabled, isTrue);
  });

  testWidgets('porte unlock : mauvais code -> erreur, bon code -> ouvre',
      (tester) async {
    ChatLockStore.instance.setAppLock('4321');
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppLockGate(
          mode: AppLockGateMode.unlock,
          onDone: () => done = true,
          authenticator: FakeBio(available: false),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Kite verrouillé'), findsOneWidget);
    await typeCode(tester, '1111');
    await tester.pump();
    expect(find.text('Code incorrect'), findsOneWidget);
    expect(done, isFalse);

    await typeCode(tester, '4321');
    await tester.pump();
    expect(done, isTrue);
  });

  testWidgets('porte unlock : biométrie auto-prompt puis ouverture',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setAppLock('9999');
    store.setAppBiometrics(true);
    final bio = FakeBio(available: true, result: true);
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppLockGate(
          mode: AppLockGateMode.unlock,
          onDone: () => done = true,
          authenticator: bio,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Prompt lancé automatiquement, succès -> porte ouverte sans code.
    expect(bio.promptCount, 1);
    expect(done, isTrue);
  });

  testWidgets('porte unlock : refus biométrique -> repli code PIN',
      (tester) async {
    final store = ChatLockStore.instance;
    store.setAppLock('4321');
    store.setAppBiometrics(true);
    final bio = FakeBio(available: true, result: false);
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppLockGate(
          mode: AppLockGateMode.unlock,
          onDone: () => done = true,
          authenticator: bio,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(bio.promptCount, 1);
    expect(done, isFalse);
    expect(find.text('Biométrie non reconnue — utilisez le code'),
        findsOneWidget);

    // Le pad PIN reste la solution de secours.
    await typeCode(tester, '4321');
    await tester.pump();
    expect(done, isTrue);
  });
}
