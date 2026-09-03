import 'dart:async';
import 'package:flutter/foundation.dart';

import 'local_store.dart';
import 'models.dart';

/// Implémentation 100% hors-ligne de l'API : même surface que [KiteApi],
/// mais tout est servi par la base locale. Aucun serveur requis — l'app
/// fonctionne (lecture, envoi, réception simulée, appels) sans réseau.
///
/// Les messages envoyés sont persistés localement ; un écho simulé d'un
/// correspondant arrive après quelques secondes pour rendre la conversation
/// vivante même hors ligne.
class OfflineApi {
  OfflineApi({this.meId = 'u-julien'}) {
    _init();
  }

  final String meId;
  LocalStore? _store;

  Future<void> _init() async {
    final store = await LocalStore.instance();
    _store = store;
    store.changes.listen((_) {
      shellRevision.value++;
      _events.add(ServerEvent('shell', {'userId': meId}));
    });
    shellRevision.value++;
  }

  /// Incrémenté à chaque mutation locale (équivalent de l'event "shell").
  final ValueNotifier<int> shellRevision = ValueNotifier<int>(0);

  /// Flux d'événements locaux : mutations de la base (event "shell") et
  /// échos simulés (event "message"). Même forme que les événements serveur.
  final StreamController<ServerEvent> _events =
      StreamController<ServerEvent>.broadcast();

  bool get ready => _store != null;

  LocalStore get _s {
    final s = _store;
    if (s == null) {
      throw StateError('OfflineApi pas encore initialisé');
    }
    return s;
  }

  // ---------- Lecture ----------

  Future<List<Chat>> fetchChats() async => _s.shellFor(meId).chats;

  Future<AppShell> fetchAppShell() async => _s.shellFor(meId);

  /// Matching de contacts 100% local : par téléphone (normalisé) puis par nom.
  Future<List<Map<String, dynamic>>> matchContacts(
      List<Map<String, dynamic>> contacts) async {
    String normalize(String p) {
      final digits = p.replaceAll(RegExp(r'[^0-9]'), '');
      return digits.length > 9 ? digits.substring(digits.length - 9) : digits;
    }

    final byPhone = <String, User>{};
    final byName = <String, User>{};
    for (final u in _s.users) {
      if (u.phone.isNotEmpty) byPhone[normalize(u.phone)] = u;
      byName[u.name.toLowerCase()] = u;
    }
    final out = <Map<String, dynamic>>[];
    for (final c in contacts) {
      final name = (c['name'] as String?) ?? '';
      final phones = (c['phones'] as List?)?.cast<String>() ?? const [];
      String? userId;
      String? userName;
      String via = '';
      for (final p in phones) {
        final u = byPhone[normalize(p)];
        if (u != null) {
          userId = u.id;
          userName = u.name;
          via = 'phone';
          break;
        }
      }
      if (userId == null) {
        final u = byName[name.trim().toLowerCase()];
        if (u != null) {
          userId = u.id;
          userName = u.name;
          via = 'name';
        }
      }
      out.add({
        'name': name,
        'phones': phones,
        if (userId != null) 'userId': userId,
        if (userName != null) 'userName': userName,
        if (via.isNotEmpty) 'via': via,
      });
    }
    return out;
  }

  Future<List<Message>> fetchMessages(String chatId) async =>
      _s.messagesFor(chatId, meId);

  // ---------- Envoi ----------

  Future<Message> sendMessage(
    String chatId, {
    String type = 'text',
    String text = '',
    Map<String, dynamic>? media,
    String? replyTo,
  }) async {
    final m = _s.addMessage(chatId, meId, type, text,
        media: media, replyTo: replyTo);
    _maybeEcho(chatId);
    return m;
  }

  Future<Chat> createChat(String type, String name, List<String> memberIds) =>
      Future.value(_s.createChat(type, name, [meId, ...memberIds]));

  // ---------- Actions sur messages ----------

  Future<void> toggleReaction(String messageId, String emoji) async =>
      _s.toggleReaction(messageId, meId, emoji);

  Future<void> editMessage(String messageId, String text) async =>
      _s.editMessage(messageId, meId, text);

  Future<void> deleteMessage(String messageId, {required String mode}) async =>
      _s.deleteMessage(messageId, meId, mode);

  Future<void> votePoll(String messageId, int optionIndex) async =>
      _s.votePoll(messageId, meId, optionIndex);

  Future<bool> toggleStar(String messageId) async =>
      _s.toggleStar(messageId, meId);

  Future<void> setChatArchived(String chatId, {required bool archived}) async {
    _s.setArchived(chatId, meId, archived);
  }

  Future<void> setChatPinned(String chatId, {required bool pinned}) async {
    _s.setPinned(chatId, meId, pinned);
  }

  Future<void> deleteChat(String chatId) async => _s.deleteChatFor(chatId, meId);

  Future<void> setChatMuted(String chatId, {String? duration}) async {
    _s.setMute(chatId, meId, duration);
  }

  Future<void> setChatNotifs(String chatId, {NotifPrefs? prefs}) async {
    _s.setNotifs(chatId, meId, prefs);
  }

  Future<void> setNotifDefaults({NotifPrefs? prefs}) async {
    _s.setNotifDefaults(meId, prefs);
  }

  Future<void> sendTyping(String chatId) async {}
  // Hors-ligne, il n'y a personne d'autre à qui signaler la saisie.

  // ---------- Appels ----------

  Future<void> logCall(String chatId,
      {String kind = 'audio', String direction = 'outgoing'}) async {
    _s.logCall(chatId, meId, kind: kind, direction: direction);
  }

  /// Appel "entrant" simulé localement (l'app est autonome).
  Future<Map<String, dynamic>> initiateCall(String chatId,
      {String kind = 'audio'}) async {
    final chat = _s.chats.where((c) => c.id == chatId).firstOrNull;
    await logCall(chatId, kind: kind, direction: 'outgoing');
    return {
      'id': 'call-${DateTime.now().microsecondsSinceEpoch}',
      'chatId': chatId,
      'callerId': meId,
      'callerName': _s.userById(meId)?.name ?? meId,
      'kind': kind,
      'status': 'ringing',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'simulated': true,
      if (chat != null) 'chatName': chat.name,
    };
  }

  Future<void> respondCall(String callId, String status) async {
    // Hors ligne, l'appel simulé se termine immédiatement (journal local).
    _s.logCall(_s.chats.isNotEmpty ? _s.chats.first.id : '', meId,
        kind: 'audio', direction: status == 'accepted' ? 'incoming' : 'missed');
  }

  // ---------- Appels planifiés ----------

  Future<List<ScheduledCall>> fetchScheduledCalls() async =>
      _s.scheduledCalls
          .where((s) => s.userId == meId || s.memberIds.contains(meId))
          .toList();

  Future<ScheduledCall> createScheduledCall({
    required String title,
    required int scheduledAt,
    String kind = 'audio',
    List<String> memberIds = const [],
    String chatId = '',
    bool reminder = false,
  }) async {
    return _s.addScheduledCall(
      meId: meId,
      title: title,
      scheduledAt: scheduledAt,
      kind: kind,
      memberIds: memberIds,
      chatId: chatId,
      reminder: reminder,
    );
  }

  Future<ScheduledCall> toggleScheduledReminder(String id) async {
    final updated = _s.toggleScheduledReminder(id);
    if (updated == null) {
      throw StateError('appel planifié introuvable');
    }
    return updated;
  }

  Future<void> deleteScheduledCall(String id) async {
    _s.deleteScheduledCall(id);
  }

  // ---------- Temps réel (flux local) ----------

  /// Flux d'événements locaux : réagit aux mutations de la base (et échos
  /// simulés). Même forme d'événements que le serveur ({type, data}).
  /// Diffusé en broadcast : plusieurs abonnés possibles (CallCenter,
  /// ConversationScreen, MessageNotifier), `lastEventId` sans effet local.
  Stream<ServerEvent> realtime({int lastEventId = 0}) => _events.stream;

  // ---------- Écho simulé d'un correspondant ----------

  static const _echoReplies = [
    'Bien reçu 👍',
    'Ok, ça marche !',
    'Je te réponds dans 5 min',
    'Parfait, merci !',
    'Haha exactement 😄',
  ];

  Timer? _echoTimer;

  void _maybeEcho(String chatId) {
    _echoTimer?.cancel();
    _echoTimer = Timer(const Duration(seconds: 3), () {
      if (_store == null) return;
      final chat = _s.chats.where((c) => c.id == chatId).firstOrNull;
      if (chat == null) return;
      final other = chat.memberIds.where((id) => id != meId).firstOrNull;
      if (other == null) return; // pas de correspondant (auto-conversation)
      final reply = _echoReplies[DateTime.now().second % _echoReplies.length];
      final m = _s.addMessage(chatId, other, 'text', reply);
      // Livré + lu immédiatement (simulation locale).
      final stored = m.copyWith(
        deliveredTo: [meId],
        readBy: [meId],
      );
      _s.upsertMessage(stored);
      // Notifié comme un vrai message entrant (notifications, UI).
      _events.add(ServerEvent('message', _s.messageToJson(stored)));
    });
  }

  void dispose() {
    _echoTimer?.cancel();
    _events.close();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
