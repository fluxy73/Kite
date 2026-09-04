import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/chat_lock.dart';

/// Comportement réel du verrou de discussion : pose du code, déverrouillage,
/// retrait, persistance sur disque, auto-lock. Aucun serveur impliqué — le
/// verrou est un réglage de l'appareil.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kite-lock-test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ChatLockStore fresh() {
    final store = ChatLockStore.instance;
    store.resetForTest(file: File('${tmp.path}/lock.json'));
    return store;
  }

  test('setLock -> locked, canOpen, code invalide refuse', () {
    final store = fresh();
    expect(store.isLocked('c1'), isFalse);

    // Code invalide : pas 4 chiffres.
    expect(store.setLock('c1', '12'), isFalse);
    expect(store.setLock('c1', 'abcd'), isFalse);
    expect(store.setLock('c1', '12345'), isFalse);
    expect(store.isLocked('c1'), isFalse);

    expect(store.setLock('c1', '1234'), isTrue);
    expect(store.isLocked('c1'), isTrue);
    // Posé à l'instant : ouvert pour la session en cours.
    expect(store.canOpen('c1'), isTrue);

    // Double verrou refusé.
    expect(store.setLock('c1', '9999'), isFalse);
  });

  test('unlock : mauvais code refuse, bon code déverrouille, lock referme', () {
    final store = fresh();
    store.setLock('c1', '4321');
    store.lock('c1'); // simule une session précédente refermée
    expect(store.canOpen('c1'), isFalse);

    expect(store.unlock('c1', '0000'), isFalse);
    expect(store.canOpen('c1'), isFalse);

    expect(store.unlock('c1', '4321'), isTrue);
    expect(store.canOpen('c1'), isTrue);

    store.lock('c1');
    expect(store.canOpen('c1'), isFalse);
  });

  test('removeLock : exige le bon code', () {
    final store = fresh();
    store.setLock('c1', '1111');
    store.lock('c1');

    expect(store.removeLock('c1', '2222'), isFalse);
    expect(store.isLocked('c1'), isTrue);

    expect(store.removeLock('c1', '1111'), isTrue);
    expect(store.isLocked('c1'), isFalse);
    expect(store.canOpen('c1'), isTrue);
  });

  test('changeCode : ancien requis, nouveau valide', () {
    final store = fresh();
    store.setLock('c1', '1111');
    store.lock('c1');

    expect(store.changeCode('c1', '2222', '3333'), isFalse);
    expect(store.changeCode('c1', '1111', '33'), isFalse); // invalide
    expect(store.changeCode('c1', '1111', '3333'), isTrue);

    // L'ancien ne marche plus, le nouveau oui.
    expect(store.unlock('c1', '1111'), isFalse);
    expect(store.unlock('c1', '3333'), isTrue);
  });

  test('le verrou survit au redémarrage (même fichier)', () {
    final f = File('${tmp.path}/lock.json');
    var store = fresh();
    store.setLock('c1', '9876');

    // "Redémarrage" : réinitialisation + relecture du même fichier.
    store = ChatLockStore.instance;
    store.resetForTest(file: f);
    expect(store.isLocked('c1'), isTrue,
        reason: 'le verrou persiste sur disque');
    expect(store.canOpen('c1'), isFalse,
        reason: 'la session neuve est verrouillée');
    expect(store.unlock('c1', '9876'), isTrue);
  });

  test('lockAll referme toutes les conversations déverrouillées', () {
    final store = fresh();
    store.setLock('c1', '1111');
    store.setLock('c2', '2222');
    expect(store.canOpen('c1'), isTrue);
    expect(store.canOpen('c2'), isTrue);

    store.lockAll();
    expect(store.canOpen('c1'), isFalse);
    expect(store.canOpen('c2'), isFalse);
  });

  testWidgets('LockGate mode unlock : erreur sur mauvais code, onDone sur bon',
      (tester) async {
    final store = fresh();
    store.setLock('c1', '1590');
    store.lock('c1');

    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LockGate(
          chatId: 'c1',
          chatName: 'Lucas Martin',
          mode: LockGateMode.unlock,
          onDone: () => done = true,
        ),
      ),
    ));

    expect(find.text('Discussion verrouillée'), findsOneWidget);
    expect(find.text('Lucas Martin'), findsOneWidget);

    // Mauvais code : message d'erreur, porte toujours fermée.
    for (final d in ['1', '1', '1', '1']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    expect(done, isFalse);
    expect(find.text('Code incorrect'), findsOneWidget);

    // Bon code : onDone déclenché.
    for (final d in ['1', '5', '9', '0']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    expect(done, isTrue);
  });

  testWidgets(
      'LockGate mode setup : confirmation requise, codes differents refusent',
      (tester) async {
    final store = fresh();
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LockGate(
          chatId: 'c2',
          chatName: 'Emma Bernard',
          mode: LockGateMode.setup,
          onDone: () => done = true,
        ),
      ),
    ));

    expect(find.text('Choisissez un code à 4 chiffres'), findsOneWidget);
    for (final d in ['7', '3', '7', '3']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Confirmez le code'), findsOneWidget);

    // Confirmation différente : retour à l'étape 1, rien posé.
    for (final d in ['0', '0', '0', '0']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Les codes ne correspondent pas, recommencez'),
        findsOneWidget);
    expect(store.isLocked('c2'), isFalse);

    // Nouvelle saisie + confirmation identique.
    for (final d in ['7', '3', '7', '3']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pump();
    for (final d in ['7', '3', '7', '3']) {
      await tester.tap(find.text(d).last);
      await tester.pump();
    }
    await tester.pump();
    expect(done, isTrue);
    expect(store.isLocked('c2'), isTrue);
    expect(store.unlock('c2', '7373'), isTrue);
  });
}
