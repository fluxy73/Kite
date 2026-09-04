import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/models.dart';
import 'package:kite/screens/conversation_screen.dart';
import 'package:kite/translation.dart';

/// Parcours réel : appui long -> « Traduire » -> indicateur « Traduction… »
/// -> résultat affiché sous la bulle, puis bascule (re-tap -> disparition).
/// Le traducteur est injecté (flutter_test bloque les sockets ; la couche
/// HTTP réelle est couverte par translation_test.dart).
void main() {
  testWidgets('appui long -> Traduire -> résultat sous la bulle',
      (tester) async {
    final api = _FakeApi();
    final chat = _seedChat();

    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(
        api: api,
        chat: chat,
        translator: _StubTranslator(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Appui long sur la bulle de message -> menu contextuel.
    await tester.longPress(find.text('Bonjour le monde').last);
    await tester.pumpAndSettle();

    expect(find.text('Traduire'), findsOneWidget);
    await tester.tap(find.text('Traduire'));
    await tester.pump(); // lance le Future + setState '…'
    await tester.pump(const Duration(milliseconds: 50));

    // La traduction s'affiche sous la bulle, l'indicateur a disparu.
    expect(find.text('Hello World'), findsOneWidget);
    expect(find.text('Traduction…'), findsNothing);

    // Re-tap sur Traduire -> bascule, la traduction disparaît.
    await tester.longPress(find.text('Bonjour le monde').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Traduire'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Hello World'), findsNothing);
  });
}

/// Seed minimal : une conversation DM avec un message texte reçu.
Chat _seedChat() => const Chat(
      id: 'c-test',
      type: 'dm',
      name: 'Lucas Martin',
      memberIds: ['u-julien', 'u-lucas'],
      adminIds: [],
    );

class _StubTranslator implements TranslationService {
  @override
  Future<String> translate(String text, String to, {String from = ''}) async {
    if (text != 'Bonjour le monde') {
      throw TranslationException('texte inattendu');
    }
    return 'Hello World';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeApi extends KiteApi {
  _FakeApi() : super('http://testserver');

  final Map<String, List<Message>> _messages = {
    'c-test': [
      Message(
        id: 'm1',
        chatId: 'c-test',
        senderId: 'u-lucas',
        type: 'text',
        text: 'Bonjour le monde',
        createdAt: DateTime.now().millisecondsSinceEpoch - 60000,
      ),
    ],
  };

  @override
  String get meId => 'u-julien';

  @override
  Future<List<Message>> fetchMessages(String chatId) async =>
      _messages[chatId] ?? [];

  @override
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {}
}
