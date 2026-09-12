import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/local_store.dart';
import 'package:kite/offline_api.dart';
import 'package:kite/pairing_discovery.dart';

/// Round-trip réel du jumelage : deux nœuds sur localhost (les deux côtés
/// de la feuille). Le « téléphone B » est un socket UDP brut qui répond aux
/// annonces de A — exactement ce que fait une deuxième instance de l'app.
///
/// 1. découverte : A annonce (unicast vers B, seam de test), B répond →
///    A voit B apparaître sur son radar ;
/// 2. résolution : le code affiché par B est résolu par A contre les pairs
///    vus sur le réseau ;
/// 3. persistance : A enregistre B comme contact (upsertUser, chemin réel
///    de la feuille en mode hors-ligne) ;
/// 4. DM : la conversation avec B existe, membre des deux côtés.
void main() {
  late RawDatagramSocket peerB;
  late String bId;
  late String bCode;
  late Directory tmp;
  late int bPort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kite-pair');
    LocalStore.resetForTest();
    LocalStore.overridePathForTest('${tmp.path}/kite-local.json');
    await PairingDiscovery.instance.dispose();
    bId = 'u-zoe';
    bCode = PairingDiscovery.shortCode(bId);

    // Téléphone B : écoute sur un port éphémère, répond à chaque annonce
    // de A (identité de B) — une seule réponse par annonce reçue.
    peerB = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    bPort = peerB.port;
    peerB.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = peerB.receive();
      if (dg == null) return;
      final msg = utf8.decode(dg.data);
      if (!msg.startsWith('KITE1 ')) return;
      final hello = utf8.encode(
          'KITE1 ${jsonEncode({'v': 1, 'id': bId, 'name': 'Zoé'})}');
      peerB.send(hello, dg.address, dg.port);
    });

    // Seam de test : A annonce en unicast vers B (pas de broadcast en test).
    PairingDiscovery.testAnnounceTo = InternetAddress.loopbackIPv4;
    PairingDiscovery.testAnnouncePort = bPort;
  });

  tearDown(() async {
    await PairingDiscovery.instance.dispose();
    peerB.close();
    PairingDiscovery.testAnnounceTo = null;
    PairingDiscovery.testAnnouncePort = null;
    tmp.deleteSync(recursive: true);
  });

  test('découverte → résolution du code → contact → DM', () async {
    // A ouvre la feuille : démarre l'écoute + les annonces.
    final started = await PairingDiscovery.instance
        .start(meId: 'u-julien', meName: 'Julien');
    expect(started, isTrue, reason: 'UDP doit démarrer sur localhost');

    // 1. Découverte : B répond, A le voit apparaître.
    final seen = await PairingDiscovery.instance.peers
        .map((l) => l.any((u) => u.id == bId))
        .firstWhere((v) => v);
    expect(seen, isTrue);

    // 2. Résolution du code affiché par B.
    final resolved = PairingDiscovery.instance.resolveCode(bCode, const []);
    expect(resolved, isNotNull);
    expect(resolved!.id, bId);
    expect(resolved.name, 'Zoé');

    // 3. Enregistrement du contact (chemin réel de la feuille, offline).
    // (Le store est chargé en async dans le constructeur : garantir l'init
    // avant la première mutation.)
    await LocalStore.instance();
    final api = OfflineApi();
    await Future<void>.delayed(Duration.zero);
    final stored = await api.upsertUser(resolved);
    expect(stored.id, bId);
    final shell = await api.fetchAppShell();
    expect(shell.users.any((u) => u.id == bId), isTrue,
        reason: 'B est maintenant un contact de A');

    // 4. La DM s'ouvre : création via le même chemin que la feuille.
    final chat = await api.createChat('dm', resolved.name, [resolved.id]);
    expect(chat.type, 'dm');
    expect(chat.memberIds, containsAll([api.meId, bId]));
    final store = await LocalStore.instance();
    expect(store.findDmWith(bId, api.meId)!.id, chat.id);
  });

  test('code inconnu : résolution échoue proprement', () async {
    await PairingDiscovery.instance
        .start(meId: 'u-julien', meName: 'Julien');
    expect(PairingDiscovery.instance.resolveCode('inconnu-99', const []),
        isNull);
    expect(PairingDiscovery.instance.resolveCode('', const []), isNull);
  });
}
