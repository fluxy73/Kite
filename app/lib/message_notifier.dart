import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Notification locale de message entrant (in-app).
class MessageNotification {
  const MessageNotification({
    required this.chatId,
    required this.message,
    required this.chatName,
    String? senderName,
  }) : _senderName = senderName;

  final String chatId;
  final Message message;
  final String chatName;
  final String? _senderName;

  String get senderName => _senderName ?? message.senderId;
  String get body => message.preview();
}

/// Centre de notifications locales de messages entrants : écoute le flux
/// temps réel (serveur WebSocket/SSE ou flux local hors-ligne) et expose la
/// dernière notification éligible via [last].
///
/// Une notification est émise si :
/// - l'event est un `message` envoyé par quelqu'un d'autre que moi ;
/// - la conversation n'est pas muette pour moi (`chat.mutedFor(meId)`) ;
/// - la conversation n'est pas ouverte à l'écran ([openChat]/[closeChat]).
class MessageNotifier {
  MessageNotifier._();

  static final MessageNotifier instance = MessageNotifier._();

  /// Dernière notification éligible (consommée par le popup de main.dart).
  final ValueNotifier<MessageNotification?> last = ValueNotifier(null);

  StreamSubscription<ServerEvent>? _sub;
  final Set<String> _openChats = {};
  final Map<String, String> _userNames = {};
  String? _meId;
  dynamic _api;

  void start(dynamic api, {String? meId}) {
    if (_sub != null) return; // déjà démarré
    _api = api;
    _meId = meId;
    _sub = api.realtime().listen(handleEvent, onError: (_) {});
    _loadUsers(api);
  }

  Future<void> _loadUsers(dynamic api) async {
    try {
      final shell = await api.fetchAppShell() as AppShell;
      for (final u in shell.users) {
        _userNames[u.id] = u.name;
      }
    } catch (_) {
      // Noms indisponibles : les notifications tomberont sur l'id brut.
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    last.value = null;
  }

  /// Consomme la notification courante (après affichage du popup).
  void reset() => last.value = null;

  /// La conversation [chatId] est affichée : pas de popup pour elle.
  void openChat(String chatId) => _openChats.add(chatId);

  void closeChat(String chatId) => _openChats.remove(chatId);

  /// Traite un événement temps réel (public pour les tests).
  @visibleForTesting
  Future<void> handleEvent(ServerEvent ev) async {
    if (ev.type != 'message') return;
    final m = Message.fromJson(ev.data);
    if (m.senderId == _meId) return; // mon propre message
    if (_openChats.contains(m.chatId)) return; // conversation à l'écran
    final chat = await _chat(m.chatId);
    if (chat == null) return;
    // Sourdine active : aucune notification.
    if (chat.mutedFor(_meId ?? '')) return;
    last.value = MessageNotification(
      chatId: chat.id,
      message: m,
      chatName: chat.name.isNotEmpty ? chat.name : _otherName(chat),
      senderName: _userNames[m.senderId] ?? m.senderId,
    );
  }

  String _otherName(Chat chat) {
    for (final id in chat.memberIds) {
      if (id != _meId) return _userNames[id] ?? id;
    }
    return chat.id;
  }

  Future<Chat?> _chat(String chatId) async {
    try {
      final chats = await _api.fetchChats() as List<Chat>;
      for (final c in chats) {
        if (c.id == chatId) return c;
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
