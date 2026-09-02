import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Client du serveur Go (server/). Zéro dépendance externe (dart:io).
class KiteApi {
  KiteApi(this.baseUrl, {this.meId = 'u-julien', HttpClient? httpClient})
      : _http = httpClient ??
            (HttpClient()..connectionTimeout = const Duration(seconds: 6));

  /// URL du serveur. Exemples :
  ///  - Desktop/Linux/Windows : http://localhost:8080
  ///  - Émulateur Android     : http://10.0.2.2:8080
  final String baseUrl;
  final String meId;

  final HttpClient _http;

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

  /// Sonde de connectivité : vérifie que le serveur répond.
  Future<void> pingHealth() async {
    await _send('GET', '/api/health');
  }

  Future<List<Chat>> fetchChats() async {
    final raw = await _send('GET', '/api/chats', query: {'userId': meId});
    return (raw as List).map((e) => Chat.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Agrégat de l'écran principal : discussions + appels.
  Future<AppShell> fetchAppShell() async {
    final raw = await _send('GET', '/api/shell', query: {'userId': meId});
    return AppShell.fromJson(raw as Map<String, dynamic>);
  }

  /// Résultat de matching d'un contact de l'appareil contre les utilisateurs.
  Future<List<Map<String, dynamic>>> matchContacts(
      List<Map<String, dynamic>> contacts) async {
    final raw = await _send('POST', '/api/contacts/match',
        query: {'userId': meId}, body: {'contacts': contacts});
    return ((raw as Map)['matches'] as List? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// Journalise un appel (message de type "call") dans une conversation.
  Future<void> logCall(String chatId, {String kind = 'audio', String direction = 'outgoing'}) async {
    await _send('POST', '/api/calls/log', query: {'userId': meId}, body: {
      'chatId': chatId,
      'kind': kind,
      'direction': direction,
    });
  }

  /// Signalisation temps réel : initie un appel (broadcast WebSocket/SSE).
  Future<Map<String, dynamic>> initiateCall(String chatId, {String kind = 'audio'}) async {
    final raw = await _send('POST', '/api/calls/initiate', query: {'userId': meId}, body: {
      'chatId': chatId,
      'kind': kind,
    });
    return (raw as Map).cast<String, dynamic>();
  }

  /// Relaye un signal WebRTC (offer | answer | ice) aux autres participants.
  Future<void> sendCallSignal(String callId, String kind, Map<String, dynamic> payload) async {
    await _send('POST', '/api/calls/signal', query: {'userId': meId}, body: {
      'callId': callId,
      'kind': kind,
      'payload': payload,
    });
  }

  /// Répond à un appel entrant (accepted | declined) — broadcast temps réel.
  Future<void> respondCall(String callId, String status) async {
    await _send('POST', '/api/calls/respond', query: {'userId': meId}, body: {
      'callId': callId,
      'status': status,
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

  /// Marque/démarque un message en favori (retourne true si désormais favori).
  Future<bool> toggleStar(String messageId) async {
    final raw = await _send('POST', '/api/messages/$messageId/star', body: {
      'userId': meId,
    });
    return ((raw as Map)['starredBy'] as List? ?? []).contains(meId);
  }

  /// Archive ou désarchive une conversation pour moi.
  Future<void> setChatArchived(String chatId, {required bool archived}) async {
    await _send('POST', '/api/chats/$chatId/archive', query: {'userId': meId}, body: {
      'archived': archived,
    });
  }

  /// Épingle ou détache une conversation pour moi.
  Future<void> setChatPinned(String chatId, {required bool pinned}) async {
    await _send('POST', '/api/chats/$chatId/pin', query: {'userId': meId}, body: {
      'pinned': pinned,
    });
  }

  /// Supprime la discussion pour moi (l'historique et les autres membres
  /// sont conservés ; un nouveau message la fait renaître).
  Future<void> deleteChat(String chatId) async {
    await _send('POST', '/api/chats/$chatId/delete', query: {'userId': meId});
  }

  /// Rend muette la conversation pour moi jusqu'à l'expiration donnée
  /// ([duration] : 8h | 1w | always), ou démute (duration: null).
  Future<void> setChatMuted(String chatId, {String? duration}) async {
    await _send('POST', '/api/chats/$chatId/mute', query: {'userId': meId},
        body: {'duration': duration ?? 'off'});
  }

  /// Notifie les autres membres que je saisis dans cette conversation.
  Future<void> sendTyping(String chatId) async {
    await _send('POST', '/api/typing', query: {'userId': meId}, body: {
      'chatId': chatId,
    });
  }

  // ---------- Appels planifiés ----------

  /// Liste les appels planifiés visibles pour moi.
  Future<List<ScheduledCall>> fetchScheduledCalls() async {
    final raw = await _send('GET', '/api/scheduled-calls', query: {'userId': meId});
    return (raw as List).map((e) => ScheduledCall.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Crée un appel planifié (titre, date/heure, participants, rappel).
  Future<ScheduledCall> createScheduledCall({
    required String title,
    required int scheduledAt,
    String kind = 'audio',
    List<String> memberIds = const [],
    String chatId = '',
    bool reminder = false,
  }) async {
    final raw = await _send('POST', '/api/scheduled-calls', query: {'userId': meId}, body: {
      'title': title,
      'scheduledAt': scheduledAt,
      'kind': kind,
      'memberIds': memberIds,
      'chatId': chatId,
      'reminder': reminder,
    });
    return ScheduledCall.fromJson(raw as Map<String, dynamic>);
  }

  /// Active/désactive le rappel d'un appel planifié.
  Future<ScheduledCall> toggleScheduledReminder(String id) async {
    final raw = await _send('PATCH', '/api/scheduled-calls', query: {'userId': meId}, body: {'id': id});
    return ScheduledCall.fromJson(raw as Map<String, dynamic>);
  }

  /// Supprime un appel planifié.
  Future<void> deleteScheduledCall(String id) async {
    await _send('DELETE', '/api/scheduled-calls/$id', query: {'userId': meId});
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
