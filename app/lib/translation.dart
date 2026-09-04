import 'dart:convert';
import 'dart:io';

/// Traduction de messages : service MyMemory (https://api.mymemory.translated.net),
/// gratuit, sans clé API, limite généreuse en usage personnel. Repli gracieux
/// en cas d'erreur réseau : [TranslationService.translate] lève [TranslationException],
/// l'UI affiche un message clair sans casser le flux de conversation.
///
/// Le service est injectable ([HttpFetcher]) pour les tests.
class TranslationService {
  TranslationService({HttpFetcher? fetcher, Uri? baseUrl})
      : _fetcher = fetcher ?? _defaultFetcher,
        baseUrl = baseUrl ?? defaultBase;

  final HttpFetcher _fetcher;

  /// Point d'entrée du service (injectable : tests sur serveur local).
  final Uri baseUrl;

  static final Uri defaultBase =
      Uri.parse('https://api.mymemory.translated.net');

  static HttpClient _defaultFetcher() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);

  /// Traduit [text] depuis [from] (code langue source, ex. 'fr', 'en',
  /// ou '' = détection auto côté service) vers [to].
  Future<String> translate(String text, String to, {String from = ''}) async {
    final encoded = Uri.encodeQueryComponent(text);
    final fromPart = from.isEmpty ? 'Autodetect' : from;
    final uri = Uri.parse(
        '$baseUrl/get?q=$encoded&langpair=$fromPart|$to');
    try {
      final client = _fetcher();
      final req = await client.getUrl(uri);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final status = json['responseStatus'];
      if (status is num && status >= 400) {
        throw TranslationException('Service de traduction indisponible');
      }
      final data = json['responseData'] as Map<String, dynamic>?;
      final translated = data?['translatedText'] as String?;
      if (translated == null || translated.isEmpty) {
        throw TranslationException('Traduction vide');
      }
      // MyMemory renvoie parfois l'erreur dans translatedText avec un 200.
      if (translated.startsWith('MYMEMORY WARNING') ||
          translated.startsWith('PLEASE SELECT TWO DISTINCT')) {
        throw TranslationException('Langue non détectée');
      }
      return translated;
    } on TranslationException {
      rethrow;
    } catch (_) {
      throw TranslationException('Réseau indisponible');
    }
  }
}

typedef HttpFetcher = HttpClient Function();

class TranslationException implements Exception {
  TranslationException(this.message);
  final String message;

  @override
  String toString() => message;
}
