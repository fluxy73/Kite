import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:kite/translation.dart';

void main() {
  late HttpServer server;
  late Uri base;
  final responses = <String, String>{};

  setUp(() async {
    responses.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      final q = req.uri.queryParameters['q'] ?? '';
      final body = jsonEncode({
        'responseStatus': 200,
        'responseData': {'translatedText': responses[q] ?? ''}
      });
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  TranslationService service() => TranslationService(baseUrl: base);

  test('traduit le texte (serveur local déterministe)', () async {
    responses['Bonjour le monde'] = 'Hello world';
    final out = await service().translate('Bonjour le monde', 'en');
    expect(out, 'Hello world');
  });

  test('texte vide côté service -> TranslationException', () async {
    // Aucune réponse enregistrée : translatedText vide.
    await expectLater(
      service().translate('inconnu', 'en'),
      throwsA(isA<TranslationException>()),
    );
  });

  test('réponse d\'erreur (responseStatus 4xx) -> TranslationException',
      () async {
    final errServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    errServer.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'responseStatus': 403,
        'responseData': {'translatedText': ''}
      }));
      await req.response.close();
    });
    addTearDown(() async => errServer.close(force: true));
    final errBase =
        Uri.parse('http://127.0.0.1:${errServer.port}');
    await expectLater(
      TranslationService(baseUrl: errBase).translate('test', 'en'),
      throwsA(isA<TranslationException>()),
    );
  });

  test('réseau indisponible -> TranslationException', () async {
    // Port fermé : la connexion doit échouer.
    final closed = Uri.parse('http://127.0.0.1:9');
    await expectLater(
      TranslationService(baseUrl: closed).translate('test', 'en'),
      throwsA(isA<TranslationException>()),
    );
  });

  test('avertissements MyMemory traités comme erreurs', () async {
    responses['test'] = 'MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE';
    await expectLater(
      service().translate('test', 'en'),
      throwsA(isA<TranslationException>()),
    );
  });
}
