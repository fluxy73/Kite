import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/models.dart';
import 'package:kite/screens/conversation_screen.dart';

/// Régression playtest : le morph micro↔envoi doit suivre la saisie.
/// Avant correctif, _onInputChanged ne rebuildait pas — l'utilisateur
/// tapait « envoyer » et déclenche un enregistrement vocal à la place.
void main() {
  testWidgets('saisie -> appui sur le bouton droit envoie le texte', (tester) async {
    final api = _ProbeApi();
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: api, chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 1. Champs vides ou à blancs : appuyer n'envoie rien.
    await tester.tap(find.byIcon(Icons.send), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.sent, isEmpty);

    // 2. Saisie réelle puis envoi : le message part avec son texte.
    await tester.enterText(find.byType(TextField).first, 'coucou');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.sent, hasLength(1));
    expect(api.sent.single['text'], 'coucou');
  });
}

Chat _seedChat() => const Chat(
      id: 'c-test',
      type: 'dm',
      name: 'Lucas Martin',
      memberIds: ['u-julien', 'u-lucas'],
      adminIds: [],
    );

class _ProbeApi extends KiteApi {
  _ProbeApi() : super('http://testserver');

  final List<Map<String, dynamic>> sent = [];

  @override
  String get meId => 'u-julien';

  @override
  Future<List<Message>> fetchMessages(String chatId) async => <Message>[];

  @override
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {}

  @override
  Future<Message> sendMessage(String chatId,
      {String type = 'text',
      String text = '',
      String? replyTo,
      Map<String, dynamic>? media}) async {
    sent.add({'type': type, 'text': text});
    return Message(
      id: 'm-${sent.length}',
      chatId: chatId,
      senderId: 'u-julien',
      type: type,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
