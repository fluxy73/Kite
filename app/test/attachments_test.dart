import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kite/api.dart';
import 'package:kite/models.dart';
import 'package:kite/screens/chat_extras.dart';
import 'package:kite/screens/conversation_screen.dart';


// =============================================================================
// Pièces jointes réelles : les images partagent un vrai fichier (PNG 1×1
// encodé en base64, écrit dans un fichier temporaire) et la bulle le rend
// via Image.file. Fichier absent -> repli honnête (icône + label). Le
// sélecteur de contacts dégrade proprement sans permission (plateforme test).
// =============================================================================

// PNG 1x1 transparent, encodé — aucun décodeur d'image requis.
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Uint8List get _pngBytes => Uint8List.fromList(
    Uri.parse('data:image/png;base64,$_pngB64').data!.contentAsBytes());

Chat _seedChat() => const Chat(
      id: 'c-att',
      type: 'dm',
      name: 'Lucas Martin',
      memberIds: ['u-julien', 'u-lucas'],
      adminIds: [],
    );

class _ProbeApi extends KiteApi {
  _ProbeApi() : super('http://testserver');

  @override
  String get meId => 'u-julien';

  @override
  Future<List<Message>> fetchMessages(String chatId) async => <Message>[
        Message(
          id: 'm-img',
          chatId: chatId,
          senderId: 'u-lucas',
          type: 'image',
          text: '',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          media: {'path': _realPath},
        ),
        Message(
          id: 'm-missing',
          chatId: chatId,
          senderId: 'u-lucas',
          type: 'image',
          text: '',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          media: {'path': _missingPath},
        ),
      ];

  @override
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

late Directory _tmp;
late String _realPath;
late String _missingPath;

Future<void> _makeFiles() async {
  _tmp = await Directory.systemTemp.createTemp('kite-attach-test');
  _realPath = '${_tmp.path}${Platform.pathSeparator}photo.png';
  File(_realPath).writeAsBytesSync(_pngBytes);
  _missingPath = '${_tmp.path}${Platform.pathSeparator}absent.png';
  _galleryMessages = await _ProbeApi().fetchMessages('c-att');
}

late List<Message> _galleryMessages;

void main() {
  setUpAll(_makeFiles);
  tearDownAll(() async => _tmp.delete(recursive: true));

  testWidgets('bulle image : Image.file rend le vrai fichier partagé',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ConversationScreen(api: _ProbeApi(), chat: _seedChat()),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Le vrai fichier est rendu (décode le PNG 1×1).
    final img = find.byWidgetPredicate((w) =>
        w is Image && w.image is FileImage && (w.image as FileImage).file.path == _realPath);
    expect(img, findsOneWidget);
    // Aucune bulle ne rend le fichier absent via Image.file.
    final missing = find.byWidgetPredicate((w) =>
        w is Image &&
        w.image is FileImage &&
        (w.image as FileImage).file.path == _missingPath);
    expect(missing, findsNothing);
    // Le cas absent tombe sur le repli honnête.
    expect(find.text('Photo'), findsOneWidget);
  });

  testWidgets('galerie : vignette du vrai fichier, repli pour le manquant',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaGalleryScreen(
        messages: _galleryMessages,
        isMine: (_) => false,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // La vignette est le vrai fichier.
    expect(
      find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is FileImage &&
          (w.image as FileImage).file.path == _realPath),
      findsOneWidget,
    );
    // Le fichier absent produit un repli (icône image), pas une vignette cassée.
    expect(find.byIcon(Icons.image_outlined), findsAtLeastNWidgets(1));
  });
}
