import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Base de données locale hors-ligne : même modèle que le serveur Go.
/// Persistée en JSON dans le dossier de données de l'application.
///
/// Tout fonctionne sans serveur : l'app démarre avec un jeu de données
/// simulé, les messages envoyés/restants sont stockés localement et
/// survivent à un redémarrage.
class LocalStore {
  LocalStore._(this._path);

  static LocalStore? _instance;
  static String? _overridePath; // tests

  /// Chemin de fichier imposé (tests uniquement).
  static void overridePathForTest(String path) => _overridePath = path;

  /// Singleton (le chemin est résolu une seule fois).
  static Future<LocalStore> instance() async {
    if (_instance != null) return _instance!;
    final path = _overridePath ?? await _dataFilePath();
    final store = LocalStore._(path);
    await store._load();
    _instance = store;
    return store;
  }

  /// Réinitialise le singleton (tests uniquement).
  static void resetForTest() {
    _instance = null;
  }

  static Future<String> _dataFilePath() async {
    // dart:io : dossier de données par plateforme, sans plugin externe.
    //  - Android/iOS : via l'environnement fourni par le runner (HOME/Documents)
    //  - Desktop : HOME / APPDATA
    // On utilise un sous-dossier "kite" et on retombe sur le cwd en dernier
    // recours (tests).
    try {
      final env = Platform.environment;
      String base;
      if (Platform.isWindows) {
        base = env['APPDATA'] ??
            env['HOME'] ??
            Directory.current.path;
      } else if (Platform.isMacOS) {
        base =
            '${env['HOME'] ?? Directory.current.path}/Library/Application Support';
      } else {
        base = env['HOME'] ?? Directory.current.path;
      }
      final dir = Directory('$base/kite');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return '${dir.path}${Platform.pathSeparator}kite-local.json';
    } catch (_) {
      return 'kite-local.json';
    }
  }

  // ---------- État ----------

  final String _path;
  List<User> users = [];
  List<Chat> chats = [];
  final Map<String, List<Message>> _messagesByChat = {};
  List<CallLog> calls = [];
  List<ScheduledCall> scheduledCalls = [];
  List<ScheduledMessage> scheduledMessages = [];

  /// Défauts de notification globaux par utilisateur (toutes ses
  /// conversations sans préférence propre).
  final Map<String, NotifPrefs> notifDefaults = {};

  /// Diffusé à chaque mutation (même sémantique que l'event "shell" serveur).
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  bool _loaded = false;

  // ---------- Chargement / persistance ----------

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(_path);
      if (f.existsSync()) {
        final decoded = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        users = (decoded['users'] as List? ?? [])
            .map((e) => User.fromJson(e as Map<String, dynamic>))
            .toList();
        chats = (decoded['chats'] as List? ?? [])
            .map((e) => Chat.fromJson(e as Map<String, dynamic>))
            .toList();
        // Nettoyage défensif : une conversation supprimée doit rester
        // cachée après un redémarrage (le champ est persisté, mais on
        // garantit l'invariant ici aussi).
        chats = [
          for (final c in chats)
            c.deletedFor.length >= c.memberIds.length
                ? c.copyWith(deletedFor: const [])
                : c
        ];
        calls = (decoded['calls'] as List? ?? [])
            .map((e) => CallLog.fromJson(e as Map<String, dynamic>))
            .toList();
        notifDefaults.addAll((decoded['notifDefaults'] as Map? ?? {}).map(
            (k, v) => MapEntry(k as String,
                NotifPrefs.fromJson(v as Map<String, dynamic>))));
        scheduledCalls = (decoded['scheduledCalls'] as List? ?? [])
            .map((e) => ScheduledCall.fromJson(e as Map<String, dynamic>))
            .toList();
        scheduledMessages = (decoded['scheduledMessages'] as List? ?? [])
            .map((e) => ScheduledMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        final msgs = decoded['messages'] as Map<String, dynamic>? ?? {};
        msgs.forEach((chatId, list) {
          _messagesByChat[chatId] = (list as List)
              .map((e) => Message.fromJson(e as Map<String, dynamic>))
              .toList();
        });
        if (users.isNotEmpty) return; // données persistées valides
      }
    } catch (_) {
      // Fichier corrompu -> on repart du seed.
    }
    _seed();
    await _persist();
  }

  Map<String, dynamic> _serialize() => {
        'users': users.map((u) => {'id': u.id, 'name': u.name, 'phone': u.phone}).toList(),
        'chats': chats
            .map((c) => {
                  'id': c.id,
                  'type': c.type,
                  'name': c.name,
                  'memberIds': c.memberIds,
                  'adminIds': c.adminIds,
                  if (c.archived.isNotEmpty) 'archived': c.archived,
                  if (c.pinned.isNotEmpty) 'pinned': c.pinned,
                  if (c.deletedFor.isNotEmpty) 'deletedFor': c.deletedFor,
                  if (c.mutes.isNotEmpty) 'mutes': c.mutes,
                  if (c.notifs.isNotEmpty)
                    'notifs': c.notifs
                        .map((k, v) => MapEntry(k, v.toJson())),
                })
            .toList(),
        'messages': _messagesByChat.map((k, v) => MapEntry(
            k, v.map((m) => messageToJson(m)).toList())),
        'calls': calls
            .map((c) => {
                  'id': c.id,
                  'name': c.name,
                  'type': c.type,
                  'userId': c.userId,
                  'group': c.group,
                  'direction': c.direction,
                  'isVideo': c.isVideo,
                  'createdAt': c.createdAt,
                })
            .toList(),
        if (notifDefaults.isNotEmpty)
          'notifDefaults': notifDefaults
              .map((k, v) => MapEntry(k, v.toJson())),
        'scheduledMessages': scheduledMessages
            .map((m) => {
                  'id': m.id,
                  'chatId': m.chatId,
                  'senderId': m.senderId,
                  'text': m.text,
                  if (m.replyTo.isNotEmpty) 'replyTo': m.replyTo,
                  'scheduledAt': m.scheduledAt,
                  'createdAt': m.createdAt,
                })
            .toList(),
        'scheduledCalls': scheduledCalls
            .map((s) => {
                  'id': s.id,
                  'title': s.title,
                  'userId': s.userId,
                  'memberIds': s.memberIds,
                  'chatId': s.chatId,
                  'scheduledAt': s.scheduledAt,
                  'kind': s.kind,
                  'reminder': s.reminder,
                  'createdAt': s.createdAt,
                })
            .toList(),
      };

  Map<String, dynamic> messageToJson(Message m) => {
        'id': m.id,
        'chatId': m.chatId,
        'senderId': m.senderId,
        'type': m.type,
        'text': m.text,
        if (m.media != null) 'media': m.media,
        'createdAt': m.createdAt,
        'edited': m.edited,
        'deleted': m.deleted,
        'deletedFor': m.deletedFor,
        'reactions': m.reactions,
        if (m.replyTo != null) 'replyTo': m.replyTo,
        'readBy': m.readBy,
        'deliveredTo': m.deliveredTo,
        if (m.starredBy.isNotEmpty) 'starredBy': m.starredBy,
      };

  Future<void> _persist() async {
    try {
      final f = File(_path);
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_serialize()));
      tmp.renameSync(f.path);
    } catch (_) {
      // Persistance best-effort (tests, FS lecture seule).
    }
  }

  // ---------- Seed (identique à l'esprit du serveur Go) ----------

  void _seed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    int min(int n) => now - n * 60 * 1000;

    users = [
      const User(id: 'u-julien', name: 'Julien Dumont', phone: '+33612345678'),
      const User(id: 'u-lucas', name: 'Lucas Martin', phone: '+33698765432'),
      const User(id: 'u-emma', name: 'Emma Bernard', phone: '+33655544433'),
      const User(id: 'u-thomas', name: 'Thomas Petit', phone: '+33622233344'),
      const User(id: 'u-sarah', name: 'Sarah Kacem', phone: '+33677788899'),
    ];

    chats = [
      const Chat(
          id: 'c-lucas',
          type: 'dm',
          name: 'Lucas Martin',
          memberIds: ['u-julien', 'u-lucas'],
          adminIds: ['u-julien']),
      const Chat(
          id: 'c-emma',
          type: 'dm',
          name: 'Emma Bernard',
          memberIds: ['u-julien', 'u-emma'],
          adminIds: ['u-julien']),
      const Chat(
          id: 'c-nova',
          type: 'group',
          name: 'Projet Nova',
          memberIds: ['u-julien', 'u-lucas', 'u-emma', 'u-thomas', 'u-sarah'],
          adminIds: ['u-julien', 'u-lucas']),
    ];

    _messagesByChat.clear();
    _messagesByChat['c-lucas'] = [
      Message(
          id: 'm-101',
          chatId: 'c-lucas',
          senderId: 'u-lucas',
          type: 'text',
          text: 'Salut ! Tu viens ce soir ? On se retrouve à 20h devant le cinéma',
          createdAt: min(14),
          reactions: const {'❤️': ['u-julien']},
          readBy: const ['u-julien'],
          deliveredTo: const ['u-julien']),
      Message(
          id: 'm-102',
          chatId: 'c-lucas',
          senderId: 'u-julien',
          type: 'text',
          text: 'Oui ! Je réserve les places',
          createdAt: min(12),
          replyTo: 'm-101',
          readBy: const ['u-lucas'],
          deliveredTo: const ['u-lucas']),
      Message(
          id: 'm-103',
          chatId: 'c-lucas',
          senderId: 'u-lucas',
          type: 'voice',
          media: const {'duration': 34},
          createdAt: min(11),
          readBy: const ['u-julien'],
          deliveredTo: const ['u-julien']),
      Message(
          id: 'm-105',
          chatId: 'c-lucas',
          senderId: 'u-julien',
          type: 'document',
          text: 'projet-nova.pdf',
          media: const {'ext': 'pdf', 'size': '8,4 Mo', 'pages': 23},
          createdAt: min(9),
          readBy: const ['u-lucas'],
          deliveredTo: const ['u-lucas']),
      Message(
          id: 'm-107',
          chatId: 'c-lucas',
          senderId: 'u-julien',
          type: 'text',
          text: 'On se retrouve à 20h15 alors',
          createdAt: min(7),
          edited: true,
          readBy: const ['u-lucas'],
          deliveredTo: const ['u-lucas']),
    ];
    _messagesByChat['c-emma'] = [
      Message(
          id: 'm-203',
          chatId: 'c-emma',
          senderId: 'u-emma',
          type: 'text',
          text: 'Merci pour les photos !',
          createdAt: min(5),
          readBy: const ['u-julien'],
          deliveredTo: const ['u-julien']),
    ];
    _messagesByChat['c-nova'] = [
      Message(
          id: 'm-302',
          chatId: 'c-nova',
          senderId: 'u-thomas',
          type: 'text',
          text: 'Build 2.4 déployé ✅',
          createdAt: min(300),
          readBy: const ['u-julien', 'u-lucas', 'u-emma', 'u-sarah'],
          deliveredTo: const ['u-julien', 'u-lucas', 'u-emma', 'u-sarah']),
      Message(
          id: 'm-304',
          chatId: 'c-nova',
          senderId: 'u-julien',
          type: 'event',
          text: 'Réunion projet',
          media: const {
            'date': '12 septembre',
            'time': '18:30',
            'location': 'Salle 204',
            'participants': 8,
          },
          createdAt: min(260),
          readBy: const ['u-lucas', 'u-emma', 'u-thomas', 'u-sarah'],
          deliveredTo: const ['u-lucas', 'u-emma', 'u-thomas', 'u-sarah']),
    ];

    calls = [
      CallLog(
          id: 'cl-1',
          type: 'audio',
          userId: 'u-lucas',
          name: 'Lucas Martin',
          direction: 'incoming',
          createdAt: min(30)),
      CallLog(
          id: 'cl-2',
          type: 'video',
          userId: 'u-emma',
          name: 'Emma Bernard',
          direction: 'outgoing',
          isVideo: true,
          createdAt: min(150)),
      CallLog(
          id: 'cl-3',
          type: 'audio',
          userId: 'u-lucas',
          name: 'Lucas Martin',
          direction: 'missed',
          createdAt: min(200)),
    ];

    scheduledCalls = [
      ScheduledCall(
          id: 'sc-1',
          title: 'Point d\'équipe',
          userId: 'u-julien',
          memberIds: const ['u-lucas', 'u-emma'],
          chatId: 'c-nova',
          scheduledAt: now + 24 * 3600 * 1000,
          kind: 'video',
          reminder: true,
          createdAt: now),
    ];

    scheduledMessages = [
      ScheduledMessage(
          id: 'sm-1',
          chatId: 'c-lucas',
          senderId: 'u-julien',
          text: 'Bon anniversaire 🎂',
          scheduledAt: now + 48 * 3600 * 1000,
          createdAt: now),
    ];
  }

  // ---------- Lectures ----------

  AppShell shellFor(String meId) {
    // Même sémantique que le serveur : masque les conversations que
    // l'utilisateur a supprimées pour lui.
    final myChats = chats
        .where((c) =>
            c.memberIds.contains(meId) && !c.deletedFor.contains(meId))
        .toList();
    return AppShell(
      users: users,
      chats: myChats,
      calls: calls,
      notifDefaults: notifDefaultsFor(meId),
      scheduledCalls: scheduledCalls
          .where((s) => s.userId == meId || s.memberIds.contains(meId))
          .toList(),
      scheduledMessages: scheduledMessagesFor(meId),
    );
  }

  List<Message> messagesFor(String chatId, String meId) {
    final list = _messagesByChat[chatId] ?? [];
    final out = list
        .where((m) => m.visibleTo(meId))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  // ---------- Mutations ----------

  Message addMessage(String chatId, String senderId, String type, String text,
      {Map<String, dynamic>? media, String? replyTo}) {
    final m = Message(
      id: 'm-${DateTime.now().microsecondsSinceEpoch}',
      chatId: chatId,
      senderId: senderId,
      type: type,
      text: text,
      media: media,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      replyTo: replyTo,
      readBy: const [],
      deliveredTo: const [],
    );
    final list = _messagesByChat.putIfAbsent(chatId, () => []);
    list.add(m);
    // Un nouveau message fait renaître la conversation pour ceux qui
    // l'avaient supprimée (comportement WhatsApp).
    _mutateChat(chatId, (c) =>
        c.deletedFor.isEmpty ? c : c.copyWith(deletedFor: const []));
    _persist();
    _changes.add(null);
    return m;
  }

  void upsertMessage(Message m) {
    final list = _messagesByChat.putIfAbsent(m.chatId, () => []);
    final idx = list.indexWhere((e) => e.id == m.id);
    if (idx >= 0) {
      list[idx] = m;
    } else {
      list.add(m);
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    _persist();
    _changes.add(null);
  }

  Message? messageById(String id) {
    for (final list in _messagesByChat.values) {
      for (final m in list) {
        if (m.id == id) return m;
      }
    }
    return null;
  }

  /// Marque/démarque un message en favori (retourne le nouvel état).
  bool toggleStar(String messageId, String userId) {
    final m = messageById(messageId);
    if (m == null) return false;
    final starred = !m.starredFor(userId);
    upsertMessage(m.copyWith(
      starredBy: starred
          ? [...m.starredBy, userId]
          : m.starredBy.where((u) => u != userId).toList(),
    ));
    return starred;
  }

  /// Archive/désarchive une conversation pour l'utilisateur donné.
  void setArchived(String chatId, String userId, bool archived) {
    _mutateChat(chatId, (c) {
      final has = c.archived.contains(userId);
      if (archived == has) return c;
      return c.copyWith(
          archived: archived
              ? [...c.archived, userId]
              : c.archived.where((u) => u != userId).toList());
    });
  }

  /// Épingle/détache une conversation pour l'utilisateur donné.
  void setPinned(String chatId, String userId, bool pinned) {
    _mutateChat(chatId, (c) {
      final has = c.pinned.contains(userId);
      if (pinned == has) return c;
      return c.copyWith(
          pinned: pinned
              ? [...c.pinned, userId]
              : c.pinned.where((u) => u != userId).toList());
    });
  }

  /// Supprime la discussion pour cet utilisateur : elle quitte sa liste,
  /// l'historique et les autres membres sont conservés. Un nouveau message
  /// la fait renaître (comportement WhatsApp).
  void deleteChatFor(String chatId, String userId) {
    _mutateChat(chatId, (c) {
      if (c.deletedFor.contains(userId)) return c;
      return c.copyWith(
        deletedFor: [...c.deletedFor, userId],
        pinned: c.pinned.where((u) => u != userId).toList(),
        archived: c.archived.where((u) => u != userId).toList(),
        // Seuls les réglages personnels sont nettoyés (parité serveur) :
        // sourdine et préférences de notification du membre qui supprime.
        mutes: {...c.mutes}..remove(userId),
        notifs: {...c.notifs}..remove(userId),
      );
    });
  }

  /// Sourdine personnelle avec expiration (même sémantique que le serveur :
  /// [duration] 8h | 1w | always, ou null pour démuter).
  void setMute(String chatId, String userId, String? duration) {
    _mutateChat(chatId, (c) {
      final mutes = {...c.mutes};
      // 'off' démute (même sémantique que le serveur).
      if (duration == null || duration == 'off') {
        mutes.remove(userId);
      } else {
        final now = DateTime.now().millisecondsSinceEpoch;
        switch (duration) {
          case '8h':
            mutes[userId] = now + 8 * 3600 * 1000;
          case '1w':
            mutes[userId] = now + 7 * 24 * 3600 * 1000;
          case 'always':
            mutes[userId] = 0x7fffffffffffff; // ~ praticamente jamais
          default:
            return c;
        }
      }
      return c.copyWith(mutes: mutes);
    });
  }

  /// Défauts de notification globaux de [userId] (prefs null/vide = défauts
  /// de l'app).
  NotifPrefs notifDefaultsFor(String userId) => notifDefaults[userId] ?? const NotifPrefs();

  void setNotifDefaults(String userId, NotifPrefs? prefs) {
    if (prefs == null || prefs.isEmpty) {
      notifDefaults.remove(userId);
    } else {
      notifDefaults[userId] = prefs;
    }
    _persist();
    _changes.add(null);
  }

  /// Préférences de notification par conversation (prefs null = défauts).
  void setNotifs(String chatId, String userId, NotifPrefs? prefs) {
    _mutateChat(chatId, (c) {
      final notifs = {...c.notifs};
      if (prefs == null || prefs.isEmpty) {
        notifs.remove(userId);
      } else {
        notifs[userId] = prefs;
      }
      return c.copyWith(notifs: notifs);
    });
  }

  void _mutateChat(String chatId, Chat Function(Chat) fn) {
    final idx = chats.indexWhere((c) => c.id == chatId);
    if (idx < 0) return;
    chats[idx] = fn(chats[idx]);
    _persist();
    _changes.add(null);
  }

  bool toggleReaction(String messageId, String userId, String emoji) {
    final m = messageById(messageId);
    if (m == null) return false;
    final reactions = Map<String, List<String>>.from(m.reactions);
    final usersFor = List<String>.from(reactions[emoji] ?? const []);
    if (usersFor.contains(userId)) {
      usersFor.remove(userId);
      if (usersFor.isEmpty) {
        reactions.remove(emoji);
      } else {
        reactions[emoji] = usersFor;
      }
    } else {
      usersFor.add(userId);
      reactions[emoji] = usersFor;
    }
    upsertMessage(m.copyWith(reactions: reactions));
    return true;
  }

  bool editMessage(String messageId, String userId, String text) {
    final m = messageById(messageId);
    if (m == null || m.senderId != userId) return false;
    upsertMessage(m.copyWith(text: text, edited: true));
    return true;
  }

  bool deleteMessage(String messageId, String userId, String mode) {
    final m = messageById(messageId);
    if (m == null) return false;
    if (mode == 'all') {
      if (m.senderId != userId) return false;
      upsertMessage(m.copyWith(deleted: true));
    } else {
      final df = List<String>.from(m.deletedFor);
      if (!df.contains(userId)) df.add(userId);
      upsertMessage(m.copyWith(deletedFor: df));
    }
    return true;
  }

  bool votePoll(String messageId, String userId, int optionIndex) {
    final m = messageById(messageId);
    if (m == null || m.media == null) return false;
    final media = Map<String, dynamic>.from(m.media!);
    final options = media['options'];
    if (options is! List || optionIndex < 0 || optionIndex >= options.length) {
      return false;
    }
    final votes = List<int>.from((media['votes'] as List? ?? []).map<int>((v) => v as int));
    if (optionIndex < votes.length) {
      votes[optionIndex] += 1;
    } else {
      while (votes.length < optionIndex) {
        votes.add(0);
      }
      votes.add(1);
    }
    media['votes'] = votes;
    final voters = List<String>.from((media['voters'] as List? ?? []).cast<String>());
    if (!voters.contains(userId)) voters.add(userId);
    media['voters'] = voters;
    upsertMessage(m.copyWith(media: media));
    return true;
  }

  Chat createChat(String type, String name, List<String> memberIds) {
    final c = Chat(
      id: 'c-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      name: name,
      memberIds: memberIds,
      adminIds: memberIds.isNotEmpty ? [memberIds.first] : const [],
    );
    chats.add(c);
    _persist();
    _changes.add(null);
    return c;
  }

  // ---------- Appels ----------

  void logCall(String chatId, String meId,
      {String kind = 'audio', String direction = 'outgoing'}) {
    final chat = chats.where((c) => c.id == chatId).firstOrNull;
    String name = chat?.name ?? '';
    bool group = chat?.isGroup ?? false;
    if (!group && chat != null) {
      final other = chat.memberIds.where((id) => id != meId).firstOrNull;
      name = users.where((u) => u.id == other).firstOrNull?.name ?? name;
    }
    calls.add(CallLog(
      id: 'cl-${DateTime.now().microsecondsSinceEpoch}',
      type: kind,
      userId: chatId,
      name: name,
      group: group,
      direction: direction,
      isVideo: kind == 'video',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    // Message de type "call" dans la conversation, comme le serveur.
    final text = direction == 'missed'
        ? (kind == 'video' ? '📹 Appel manqué' : '📞 Appel manqué')
        : (kind == 'video' ? '📹 Appel' : '📞 Appel');
    addMessage(chatId, meId, 'call', text,
        media: {'kind': kind, 'direction': direction});
    _persist();
    _changes.add(null);
  }

  // ---------- Appels planifiés ----------

  ScheduledCall addScheduledCall({
    required String meId,
    required String title,
    required int scheduledAt,
    String kind = 'audio',
    List<String> memberIds = const [],
    String chatId = '',
    bool reminder = false,
  }) {
    final sc = ScheduledCall(
      id: 'sc-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      userId: meId,
      memberIds: memberIds,
      chatId: chatId,
      scheduledAt: scheduledAt,
      kind: kind,
      reminder: reminder,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    scheduledCalls.add(sc);
    _persist();
    _changes.add(null);
    return sc;
  }

  ScheduledCall? toggleScheduledReminder(String id) {
    for (var i = 0; i < scheduledCalls.length; i++) {
      if (scheduledCalls[i].id == id) {
        final s = scheduledCalls[i];
        final updated = ScheduledCall(
          id: s.id,
          title: s.title,
          userId: s.userId,
          memberIds: s.memberIds,
          chatId: s.chatId,
          scheduledAt: s.scheduledAt,
          kind: s.kind,
          reminder: !s.reminder,
          createdAt: s.createdAt,
        );
        scheduledCalls[i] = updated;
        _persist();
        _changes.add(null);
        return updated;
      }
    }
    return null;
  }

  bool deleteScheduledCall(String id) {
    final n0 = scheduledCalls.length;
    scheduledCalls.removeWhere((s) => s.id == id);
    final removed = scheduledCalls.length != n0;
    if (removed) {
      _persist();
      _changes.add(null);
    }
    return removed;
  }

  // ---------- Messages programmés ----------

  List<ScheduledMessage> scheduledMessagesFor(String meId) {
    final member = chats.where((c) => c.memberIds.contains(meId)).map((c) => c.id).toSet();
    return scheduledMessages
        .where((m) => m.senderId == meId || member.contains(m.chatId))
        .toList();
  }

  ScheduledMessage addScheduledMessage({
    required String chatId,
    required String senderId,
    required String text,
    required int scheduledAt,
    String replyTo = '',
  }) {
    final sm = ScheduledMessage(
      id: 'sm-${DateTime.now().microsecondsSinceEpoch}',
      chatId: chatId,
      senderId: senderId,
      text: text,
      replyTo: replyTo,
      scheduledAt: scheduledAt,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    scheduledMessages.add(sm);
    _persist();
    _changes.add(null);
    return sm;
  }

  bool deleteScheduledMessage(String id, String meId) {
    final n0 = scheduledMessages.length;
    scheduledMessages.removeWhere((m) => m.id == id && m.senderId == meId);
    final removed = scheduledMessages.length != n0;
    if (removed) {
      _persist();
      _changes.add(null);
    }
    return removed;
  }

  /// Extrait les messages échus (les retire de la liste) et les délivre
  /// comme messages réels. Retourne les messages délivrés.
  List<Message> dispatchDueScheduledMessages() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = scheduledMessages.where((m) => m.scheduledAt <= now).toList();
    if (due.isEmpty) return const [];
    scheduledMessages.removeWhere((m) => m.scheduledAt <= now);
    final out = <Message>[];
    for (final sm in due) {
      final m = addMessage(sm.chatId, sm.senderId, 'text', sm.text,
          replyTo: sm.replyTo);
      out.add(m);
    }
    _persist();
    _changes.add(null);
    return out;
  }

  // ---------- Utilisateurs ----------

  User? userById(String id) {
    for (final u in users) {
      if (u.id == id) return u;
    }
    return null;
  }

  User addUser(String name) {
    final u = User(
      id: 'u-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
    );
    users.add(u);
    _persist();
    _changes.add(null);
    return u;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
