import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Client du serveur Go (server/). Zéro dépendance externe (dart:io).
class KiteApi {
  KiteApi(this.baseUrl, {this.meId = 'u-julien'});

  /// URL du serveur. Exemples :
  ///  - Desktop/Linux/Windows : http://localhost:8080
  ///  - Émulateur Android     : http://10.0.2.2:8080
  final String baseUrl;
  final String meId;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final req = await _http.openUrl(method, _uri(path, query));
    req.headers.contentType = ContentType.json;
    if (body != null) {
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final raw = await res.transform(utf8.decoder).join();
    final decoded = raw.isEmpty ? null : jsonDecode(raw);
    if (res.statusCode >= 400) {
      final msg = decoded is Map ? decoded['error']?.toString() : null;
      throw HttpException(msg ?? 'Erreur HTTP ${res.statusCode}', uri: req.uri);
    }
    return decoded;
  }

  // ---------- Lecture ----------

  Future<List<Chat>> fetchChats() async {
    final raw = await _send('GET', '/api/chats', query: {'userId': meId});
    return (raw as List).map((e) => Chat.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Agrégat de l'écran principal : discussions + communautés + appels.
  Future<AppShell> fetchAppShell() async {
    final raw = await _send('GET', '/api/shell', query: {'userId': meId});
    return AppShell.fromJson(raw as Map<String, dynamic>);
  }

  /// Crée une communauté (avec éventuellement des groupes rattachés).
  Future<Community> createCommunity({
    required String name,
    String description = '',
    List<String> groupIds = const [],
  }) async {
    final raw = await _send('POST', '/api/communities', query: {'userId': meId}, body: {
      'name': name,
      'description': description,
      'groupIds': groupIds,
    });
    return Community.fromJson(raw as Map<String, dynamic>);
  }

  /// Journalise un appel (message de type "call") dans une conversation.
  Future<void> logCall(String chatId, {String kind = 'audio', String direction = 'outgoing'}) async {
    await _send('POST', '/api/calls/log', query: {'userId': meId}, body: {
      'chatId': chatId,
      'kind': kind,
      'direction': direction,
    });
  }

  Future<List<Message>> fetchMessages(String chatId) async {
    final raw = await _send('GET', '/api/chats/$chatId/messages', query: {'userId': meId});
    return (raw as List).map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ---------- Envoi ----------

  Future<Message> sendMessage(
    String chatId, {
    String type = 'text',
    String text = '',
    Map<String, dynamic>? media,
    String? replyTo,
  }) async {
    final raw = await _send('POST', '/api/chats/$chatId/messages', query: {'userId': meId}, body: {
      'senderId': meId,
      'type': type,
      'text': text,
      'media': media,
      'replyTo': replyTo,
    });
    return Message.fromJson(raw as Map<String, dynamic>);
  }

  Future<Chat> createChat(String type, String name, List<String> memberIds) async {
    final raw = await _send('POST', '/api/chats', query: {'userId': meId}, body: {
      'type': type,
      'name': name,
      'memberIds': memberIds,
    });
    return Chat.fromJson(raw as Map<String, dynamic>);
  }

  // ---------- Actions sur messages ----------

  Future<void> toggleReaction(String messageId, String emoji) async {
    await _send('POST', '/api/messages/$messageId/react', body: {
      'userId': meId,
      'emoji': emoji,
    });
  }

  Future<void> editMessage(String messageId, String text) async {
    await _send('POST', '/api/messages/$messageId/edit', body: {
      'userId': meId,
      'text': text,
    });
  }

  Future<void> deleteMessage(String messageId, {required String mode}) async {
    await _send('POST', '/api/messages/$messageId/delete', body: {
      'userId': meId,
      'mode': mode, // me | all
    });
  }

  Future<void> votePoll(String messageId, int optionIndex) async {
    await _send('POST', '/api/messages/$messageId/vote', body: {
      'userId': meId,
      'optionIndex': optionIndex,
    });
  }

  // ---------- Temps réel (WebSocket, repli SSE) ----------

  String _wsUrl(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws').toString();
  }

  /// Flux WebSocket : même format d'événements que le SSE ({id, type, chatId, data}).
  Stream<ServerEvent> wsEvents({int lastEventId = 0}) async* {
    final ws = await WebSocket.connect(_wsUrl('/api/ws', {'userId': meId}));
    ws.add(jsonEncode({'type': 'sync', 'since': lastEventId}));
    await for (final msg in ws) {
      if (msg is! String) continue;
      try {
        final decoded = jsonDecode(msg);
        if (decoded is Map) {
          yield ServerEvent.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // ignore les trames non JSON
      }
    }
  }

  /// Temps réel : WebSocket d'abord, bascule automatique sur SSE si indisponible.
  Stream<ServerEvent> realtime({int lastEventId = 0}) async* {
    try {
      yield* wsEvents(lastEventId: lastEventId);
    } catch (_) {
      yield* events(lastEventId: lastEventId);
    }
  }

  // ---------- Temps réel (SSE) ----------

  /// Flux SSE : événements temps réel + livraison des messages en attente.
  Stream<ServerEvent> events({int lastEventId = 0}) async* {
    final req = await _http.getUrl(_uri('/api/events', {
      'userId': meId,
      'lastEventId': '$lastEventId',
    }));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('SSE refusé (${res.statusCode})', uri: req.uri);
    }
    final lines = res.transform(utf8.decoder).transform(const LineSplitter());
    String? type;
    final data = StringBuffer();
    await for (final line in lines) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield ServerEvent.parse(type ?? 'message', data.toString());
        }
        data.clear();
        type = null;
      } else if (line.startsWith('event:')) {
        type = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trim());
      }
      // les lignes "id:" sont ignorées (reconnexion gérée par lastEventId)
    }
  }
}
