import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/server_status.dart';

/// Vérifie le comportement RÉEL de l'indicateur : sonde /api/health via le
/// vrai KiteApi (transport facte injecté), bascule online/offline, et rendu
/// du badge dans l'UI. flutter_test bloque les sockets réels, seul le
/// transport HTTP est simulé.
class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.body, this.statusCode);
  final String body;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
      {Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    final ctrl = StreamController<List<int>>();
    ctrl.add(utf8.encode(body));
    ctrl.close();
    return ctrl.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.body, this.statusCode);
  final String body;
  final int statusCode;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(body, statusCode);

  @override
  Future<HttpClientResponse> get done async => _FakeResponse(body, statusCode);

  @override
  void add(List<int> data) {}

  @override
  void write(Object? obj) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// healthy=true : /api/health répond 200. Sinon openUrl lève (serveur mort,
/// comme un « connection refused » réel).
class _FakeClient implements HttpClient {
  _FakeClient(this.healthy);
  final bool healthy;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (!healthy) {
      throw const SocketException('connection refused (test)');
    }
    return _FakeRequest(jsonEncode({'ok': true}), 200);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() {
    ServerStatus.instance.stop();
    ServerStatus.instance.offlineMode = false;
  });

  test('Sonde serveur sain -> online ; serveur mort -> offline', () async {
    final okApi = KiteApi('http://testserver', httpClient: _FakeClient(true));
    ServerStatus.instance.start(okApi, serverBacked: true);
    await Future<void>.delayed(Duration.zero);
    expect(ServerStatus.instance.state.value, ServerConn.online);
    expect(ServerStatus.instance.offlineMode, isFalse);

    // Le serveur meurt : la prochaine sonde bascule en offline.
    final deadApi = KiteApi('http://testserver', httpClient: _FakeClient(false));
    ServerStatus.instance.start(deadApi, serverBacked: true);
    await Future<void>.delayed(Duration.zero);
    expect(ServerStatus.instance.state.value, ServerConn.offline);
  });

  test('Mode hors-ligne (API locale) : offline immédiat, aucune sonde', () async {
    ServerStatus.instance.start(KiteApi('http://testserver'),
        serverBacked: false); // API locale : pas de serveur à sonder
    expect(ServerStatus.instance.state.value, ServerConn.offline);
    expect(ServerStatus.instance.offlineMode, isTrue);
  });

  testWidgets('Le badge affiche En ligne / Hors ligne selon la sonde', (tester) async {
    final okApi = KiteApi('http://testserver', httpClient: _FakeClient(true));
    ServerStatus.instance.start(okApi, serverBacked: true);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ConnectionBadge())));
    await tester.pumpAndSettle();
    expect(find.text('En ligne'), findsOneWidget);

    // Le serveur devient injoignable -> le badge bascule (ValueNotifier).
    final deadApi = KiteApi('http://testserver', httpClient: _FakeClient(false));
    ServerStatus.instance.start(deadApi, serverBacked: true);
    await tester.pumpAndSettle();
    expect(find.text('Hors ligne'), findsOneWidget);

    // Le timer périodique doit être annulé DANS la zone fake-async du test.
    ServerStatus.instance.stop();
  });
}
