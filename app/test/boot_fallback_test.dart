import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/main.dart';
import 'package:kite/offline_api.dart';

/// Garantie « l'app marche sans serveur, peu importe la situation » :
///  - pas de KITE_API -> API locale immédiate (zéro réseau) ;
///  - KITE_API mais serveur down -> bascule automatique en local ;
///  - KITE_API et serveur en vie -> mode serveur.
void main() {
  test('sans KITE_API : API locale immédiate, aucune sonde réseau', () async {
    final sw = Stopwatch()..start();
    final (api, serverBacked) = await resolveApi('');
    sw.stop();
    expect(api, isA<OfflineApi>());
    expect(serverBacked, isFalse);
    // Zéro réseau : la résolution est instantanée (bien sous le timeout 3 s).
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('KITE_API injoignable : bascule automatique hors-ligne', () async {
    // Port 1 : rien n'écoute, connexion refusée immédiatement.
    final (api, serverBacked) = await resolveApi('http://127.0.0.1:1');
    expect(api, isA<OfflineApi>());
    expect(serverBacked, isFalse);
  });

  test('KITE_API joignable : mode serveur', () async {
    HttpServer? server;
    try {
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        if (req.uri.path == '/api/health') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ok': true}));
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      final (api, serverBacked) =
          await resolveApi('http://127.0.0.1:${server.port}');
      expect(api, isA<KiteApi>());
      expect(api, isNot(isA<OfflineApi>()));
      expect(serverBacked, isTrue);
    } finally {
      server?.close(force: true);
    }
  });

  test('OfflineApi reste pleinement fonctionnelle sans serveur', () async {
    final (api, serverBacked) = await resolveApi(''); // le vrai chemin de boot
    expect(api, isA<OfflineApi>());
    expect(serverBacked, isFalse);
    final shell = await api.fetchAppShell(); // boot complet sans réseau
    expect(shell.chats, isNotEmpty);
    final chat = shell.chats.first;
    await api.sendMessage(chat.id, type: 'text', text: 'hors-ligne');
    final msgs = await api.fetchMessages(chat.id);
    expect(msgs.any((m) => m.text == 'hors-ligne'), isTrue);
  });
}
