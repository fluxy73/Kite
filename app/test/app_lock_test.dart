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

  test('grace : valeurs autorisées (0/30/60), rejet des autres', () {
    final store = ChatLockStore.instance;
    store.setAppLock('1111');
    expect(store.appLockGrace, 0); // défaut : immédiat
    store.setAppLockGrace(45); // valeur non autorisée
    expect(store.appLockGrace, 0);
    store.setAppLockGrace(30);
    expect(store.appLockGrace, 30);
    store.setAppLockGrace(60);
    expect(store.appLockGrace, 60);
    store.setAppLockGrace(0);
    expect(store.appLockGrace, 0);
  });

  test('grace : persistée avec le verrou, réinitialisée au retrait', () {
    final store = ChatLockStore.instance;
    store.setAppLock('2222');
    store.setAppLockGrace(30);

    // Redémarrage simulé : même fichier.
    store.resetForTest(file: lockFile);
    expect(ChatLockStore.instance.appLockGrace, 30);

    // Retrait : grâce repart à 0 (comme la biométrie).
    expect(ChatLockStore.instance.removeAppLock('2222'), isTrue);
    expect(ChatLockStore.instance.appLockGrace, 0);
  });

  test('shouldRelockApp : immédiat = toujours re-verrouiller', () {
    final store = ChatLockStore.instance;
    store.setAppLock('3333');
    expect(store.appLockGrace, 0);
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(milliseconds: 200),
            unlockedAgo: const Duration(seconds: 1)),
        isTrue);
  });

  test('shouldRelockApp : grace 30 s — courte pause récente tolérée', () {
    final store = ChatLockStore.instance;
    store.setAppLock('4444');
    store.setAppLockGrace(30);
    // Pause de 5 s, déverrouillé il y a 10 s : dans la fenêtre de grâce.
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(seconds: 5),
            unlockedAgo: const Duration(seconds: 10)),
        isFalse);
    // Pause de 45 s : au-delà de la grâce -> verrou.
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(seconds: 45),
            unlockedAgo: const Duration(seconds: 50)),
        isTrue);
  });

  test('shouldRelockApp : grace 30 s — anti-abus (déverrouillage ancien)', () {
    final store = ChatLockStore.instance;
    store.setAppLock('5555');
    store.setAppLockGrace(30);
    // Pause de 3 s mais déverrouillé il y a 2 min : re-verrouille quand même.
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(seconds: 3),
            unlockedAgo: const Duration(minutes: 2)),
        isTrue);
  });

  test('shouldRelockApp : grace 1 min — fenêtre complète', () {
    final store = ChatLockStore.instance;
    store.setAppLock('6666');
    store.setAppLockGrace(60);
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(seconds: 59),
            unlockedAgo: const Duration(seconds: 30)),
        isFalse);
    expect(
        store.shouldRelockApp(
            pausedFor: const Duration(seconds: 61),
            unlockedAgo: const Duration(seconds: 5)),
        isTrue);
  });
}
