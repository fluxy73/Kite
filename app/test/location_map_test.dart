import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:kite/models.dart';
import 'package:kite/screens/location_map.dart';
import 'package:kite/screens/message_bubble.dart';

// =============================================================================
// Localisation réelle : la carte rend une vraie tuile OSM (ou repli honnête
// hors ligne), le lien geo: est décodable, et le tap ouvre le lien via
// url_launcher (interface plateforme mockée — aucun canal réel en test).
// =============================================================================

class _FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return true;
  }
}

Message _locMessage(double lat, double lon) => Message(
      id: 'm-loc',
      chatId: 'c-x',
      senderId: 'u-lucas',
      type: 'location',
      text: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      media: {'name': 'Position actuelle', 'lat': lat, 'lon': lon},
    );

Message _locMessageNoCoords() => Message(
      id: 'm-loc0',
      chatId: 'c-x',
      senderId: 'u-lucas',
      type: 'location',
      text: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      media: {'name': 'Position actuelle'},
    );

Widget _bubble(Message m) => MaterialApp(
      home: Scaffold(
        body: KiteMessageBubble(
          message: m,
          chat: const Chat(
              id: 'c-x', type: 'dm', name: 'L', memberIds: [], adminIds: []),
          meId: 'u-julien',
          senderName: 'Lucas',
          replyPreview: null,
          isPlaying: false,
          onLongPress: () {},
          onReact: (_) {},
          onReply: () {},
          onEdit: () {},
          onDelete: (_) {},
          onVote: (_) {},
          onVoicePlay: () {},
          onEventRsvp: (_) {},
          onOpenMedia: () {},
          rsvpYes: false,
          rsvpMaybe: false,
        ),
      ),
    );

void main() {
  test('tileFor : mathématique XYZ de référence (Paris, z=15)', () {
    const map = KiteLocationMap(latitude: 48.8566, longitude: 2.3522);
    // Valeur de référence calculée indépendamment (schéma XYZ standard).
    expect(map.tileFor(48.8566, 2.3522, 15), (16598, 11273));
    // Coin : latitude polaire bornée, longitude -180/180 bornée.
    expect(map.tileFor(85.0, 179.9, 2), (3, 0));
    expect(map.tileFor(-85.0, -179.9, 2), (0, 3));
  });

  test('geoUri : URI geo: conforme RFC 5870, décodable par l OS', () {
    const map = KiteLocationMap(latitude: 48.8566, longitude: 2.3522);
    final uri = Uri.parse(map.geoUri);
    expect(uri.scheme, 'geo');
    expect(uri.path, '48.8566,2.3522');
    expect(uri.queryParameters['q'], '48.8566,2.3522');
    expect(map.webUri, contains('openstreetmap.org'));
  });

  testWidgets('bulle : carte réelle avec coordonnées, repli sans', (tester) async {
    // Avec coordonnées -> KiteLocationMap rendu.
    await tester.pumpWidget(_bubble(_locMessage(48.8566, 2.3522)));
    await tester.pump();
    expect(find.byType(KiteLocationMap), findsOneWidget);
    expect(find.textContaining('48.85660, 2.35220'), findsOneWidget);

    // Sans coordonnées (message ancien) -> repli honnête, pas de carte.
    await tester.pumpWidget(_bubble(_locMessageNoCoords()));
    await tester.pump();
    expect(find.byType(KiteLocationMap), findsNothing);
    expect(find.text('Position partagée sans coordonnées'), findsOneWidget);
  });

  testWidgets('tap sur la carte : ouvre geo: via url_launcher', (tester) async {
    final fake = _FakeLauncher();
    UrlLauncherPlatform.instance = fake;

    await tester.pumpWidget(_bubble(_locMessage(48.8566, 2.3522)));
    await tester.pump();
    await tester.tap(find.byType(KiteLocationMap));
    await tester.pumpAndSettle();

    expect(fake.launched, isNotEmpty);
    expect(fake.launched.first, startsWith('geo:48.8566,2.3522'));
  });
}
