import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/models.dart';
import 'package:kite/screens/home_shell.dart';
import 'package:kite/reminder_center.dart';

/// Drives the REAL HomeShell widget (real KiteApi parsing, real state machine,
/// real adaptive branch) against a fake HttpClient transport that serves the
/// same payload shape the Go server produces. flutter_test blocks real
/// sockets, so the transport is overridden — everything above it is real.
///
/// Asserts:
///   1. narrow viewport: two tabs (Discussions/Appels), no Communautés tab,
///      tapping a chat pushes a full-screen conversation (Navigator).
///   2. wide viewport: 2-pane layout — tapping a chat swaps the conversation
///      into the right pane IN PLACE and the pane actually fetches and
///      renders that chat's messages.
/// Real KiteApi with the fake HTTP client injected and realtime() inert
/// (no WebSocket connect attempts, so no fake-async timers are left pending).
class _TestApi extends KiteApi {
  _TestApi() : super('http://testserver', httpClient: _FakeClient());

  @override
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {}
}

void main() {
  tearDown(() {
    ScheduledReminderCenter.instance.stop();
  });

  Widget host(Size size) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: size),
          child: HomeShell(api: _TestApi()),
        ),
      );

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    await tester.pumpWidget(host(size));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    debugPrint('SCREEN TEXTS: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | ')}');
  }

  testWidgets(
      'narrow: two tabs, no Communautés, tapping chat pushes conversation',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpShell(tester, const Size(400, 800));

    expect(find.text('Communautés'), findsNothing);
    // "Discussions" appears as page header AND tab label.
    expect(find.text('Discussions'), findsNWidgets(2));
    expect(find.text('Appels'), findsOneWidget); // tab only
    expect(find.text('Lucas Martin'), findsOneWidget); // chat row rendered

    // Tap the chat row -> full-screen conversation pushed (narrow = navigate).
    await tester.tap(find.text('Lucas Martin'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    // Row + pushed conversation header both present.
    expect(find.text('Lucas Martin'), findsNWidgets(2));
    // The conversation screen actually fetched and rendered the messages.
    expect(find.text('pane-rendered-message'), findsOneWidget);
  });

  testWidgets(
      'wide: 2-pane layout, tapping chat swaps right pane in place with data',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpShell(tester, const Size(1400, 900));

    expect(find.text('Communautés'), findsNothing);
    // Right pane shows the placeholder before any selection.
    expect(find.text('Sélectionnez une discussion'), findsOneWidget);
    expect(find.text('Lucas Martin'), findsOneWidget); // row in left pane

    // Tap the chat row -> conversation appears in the right pane (in place).
    await tester.tap(find.text('Lucas Martin'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Sélectionnez une discussion'), findsNothing);
    // The right pane actually fetched and rendered this chat's message.
    expect(find.text('pane-rendered-message'), findsOneWidget);
    // Left-pane row AND right-pane conversation header both visible —
    // proves the swap happened in place, not via navigation.
    expect(find.text('Lucas Martin'), findsNWidgets(2));
  });
}

// ---------------------------------------------------------------------------
// Fake transport: serves seed-shaped payloads. Only the HTTP layer is faked;
// KiteApi JSON parsing and all widget logic run for real.
// ---------------------------------------------------------------------------

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.body);
  final String body;
  @override
  final int statusCode = 200;
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
  _FakeRequest(this.responseBody);
  final String responseBody;

  @override
  HttpHeaders get headers => _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(responseBody);

  @override
  Future<HttpClientResponse> get done async => _FakeResponse(responseBody);

  @override
  void add(List<int> data) {}

  @override
  void write(Object? obj) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeClient implements HttpClient {
  String _route(Uri url) {
    if (url.path == '/api/shell') {
      return jsonEncode({
        'users': [
          {'id': 'u-julien', 'name': 'Julien Dumont', 'phone': '+33612345678'},
          {'id': 'u-lucas', 'name': 'Lucas Martin', 'phone': '+33698765432'},
        ],
        'chats': [
          {
            'id': 'c-lucas',
            'type': 'dm',
            'name': 'Lucas Martin',
            'memberIds': ['u-julien', 'u-lucas'],
            'adminIds': ['u-julien'],
          },
        ],
        'calls': [],
        'scheduledCalls': [],
      });
    }
    if (url.path.startsWith('/api/chats/c-lucas/messages')) {
      return jsonEncode([
        {
          'id': 'm-1',
          'chatId': 'c-lucas',
          'senderId': 'u-lucas',
          'type': 'text',
          'text': 'pane-rendered-message',
          'createdAt': 1700000000000,
        },
      ]);
    }
    return '{}';
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(_route(url));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
