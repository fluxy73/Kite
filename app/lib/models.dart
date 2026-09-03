import 'dart:convert';
/// Modèles miroirs de l'API du serveur Go (server/).
class User {
  const User({required this.id, required this.name, this.phone = ''});

  final String id;
  final String name;
  final String phone; // numéro enregistré, utilisé pour le matching de contacts

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        name: json['name'] as String,
        phone: json['phone'] as String? ?? '',
      );
}

/// Un contact de l'appareil avec le résultat de matching serveur.
class ContactMatch {
  const ContactMatch({
    required this.name,
    this.phones = const [],
    this.userId = '',
    this.userName = '',
    this.via = '',
  });

  final String name;
  final List<String> phones;
  final String userId; // non vide si matché à un utilisateur Kite
  final String userName;
  final String via; // phone | name

  bool get matched => userId.isNotEmpty;

  factory ContactMatch.fromJson(Map<String, dynamic> json) => ContactMatch(
        name: json['name'] as String? ?? '',
        phones: (json['phones'] as List? ?? []).cast<String>(),
        userId: json['userId'] as String? ?? '',
        userName: json['userName'] as String? ?? '',
        via: json['via'] as String? ?? '',
      );
}

/// Un appel dans l'onglet Appels.
class CallLog {
  const CallLog({
    required this.id,
    required this.name,
    this.type = 'audio',
    this.userId = '',
    this.group = false,
    this.direction = 'incoming',
    this.isVideo = false,
    this.createdAt = 0,
  });

  final String id;
  final String name;
  final String type; // audio | video
  final String userId; // contact (ou id de groupe pour un appel groupe)
  final bool group;
  final String direction; // incoming | outgoing | missed
  final bool isVideo;
  final int createdAt;

  factory CallLog.fromJson(Map<String, dynamic> json) => CallLog(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? 'audio',
        userId: json['userId'] as String? ?? '',
        group: json['group'] as bool? ?? false,
        direction: json['direction'] as String? ?? 'incoming',
        isVideo: json['isVideo'] as bool? ?? false,
        createdAt: json['createdAt'] as int? ?? 0,
      );
}

/// Appel planifié pour une date/heure future (onglet Appels).
class ScheduledCall {
  const ScheduledCall({
    required this.id,
    required this.title,
    this.userId = '',
    this.memberIds = const [],
    this.chatId = '',
    this.scheduledAt = 0,
    this.kind = 'audio',
    this.reminder = false,
    this.createdAt = 0,
  });

  final String id;
  final String title;
  final String userId; // créateur
  final List<String> memberIds; // participants
  final String chatId;
  final int scheduledAt; // timestamp d'échéance
  final String kind; // audio | video
  final bool reminder;
  final int createdAt;

  factory ScheduledCall.fromJson(Map<String, dynamic> json) => ScheduledCall(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        memberIds: (json['memberIds'] as List? ?? []).cast<String>(),
        chatId: json['chatId'] as String? ?? '',
        scheduledAt: json['scheduledAt'] as int? ?? 0,
        kind: json['kind'] as String? ?? 'audio',
        reminder: json['reminder'] as bool? ?? false,
        createdAt: json['createdAt'] as int? ?? 0,
      );
}

/// Payload agrégé de l'écran principal (get /api/shell).
class AppShell {
  const AppShell({
    this.users = const [],
    this.chats = const [],
    this.calls = const [],
    this.scheduledCalls = const [],
  });

  final List<User> users;
  final List<Chat> chats;
  final List<CallLog> calls;
  final List<ScheduledCall> scheduledCalls;

  factory AppShell.fromJson(Map<String, dynamic> json) => AppShell(
        users: (json['users'] as List? ?? [])
            .map((e) => User.fromJson(e as Map<String, dynamic>))
            .toList(),
        chats: (json['chats'] as List? ?? [])
            .map((e) => Chat.fromJson(e as Map<String, dynamic>))
            .toList(),
        calls: (json['calls'] as List? ?? [])
            .map((e) => CallLog.fromJson(e as Map<String, dynamic>))
            .toList(),
        scheduledCalls: (json['scheduledCalls'] as List? ?? [])
            .map((e) => ScheduledCall.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

enum NotifPriority { low, normal, high }

/// Préférences de notification par conversation et par utilisateur.
/// Champs null = défaut de l'app ; tout null = remise aux défauts.
class NotifPrefs {
  const NotifPrefs({this.priority, this.sound, this.preview});

  final NotifPriority? priority;
  final bool? sound;
  final bool? preview;

  /// Valeur effective : pref > défaut (son on, aperçu on, priorité normale).
  bool get soundOn => sound ?? true;
  bool get previewOn => preview ?? true;
  NotifPriority get priorityOrNormal => priority ?? NotifPriority.normal;

  /// true si aucun réglage n'est positionné (remise aux défauts).
  bool get isEmpty =>
      priority == null && sound == null && preview == null;

  NotifPrefs copyWith({NotifPriority? priority, bool? sound, bool? preview}) =>
      NotifPrefs(
        priority: priority ?? this.priority,
        sound: sound ?? this.sound,
        preview: preview ?? this.preview,
      );

  factory NotifPrefs.fromJson(Map<String, dynamic> json) => NotifPrefs(
        priority: switch (json['priority'] as String? ?? '') {
          'low' => NotifPriority.low,
          'high' => NotifPriority.high,
          'default' => NotifPriority.normal,
          _ => null,
  	},
        sound: json['sound'] as bool?,
        preview: json['preview'] as bool?,
      );

  Map<String, dynamic> toJson() => {
        if (priority != null)
          'priority': switch (priority!) {
            NotifPriority.low => 'low',
            NotifPriority.high => 'high',
            NotifPriority.normal => 'default',
          },
        if (sound != null) 'sound': sound,
        if (preview != null) 'preview': preview,
      };
}

class Chat {
  const Chat({
    required this.id,
    required this.type,
    required this.name,
    required this.memberIds,
    required this.adminIds,
    this.lastMessage,
    this.unread = 0,
    this.online = 0,
    this.archived = const [],
    this.pinned = const [],
    this.deletedFor = const [],
    this.mutes = const {},
    this.notifs = const {},
  });

  final String id;
  final String type; // dm | group
  final String name;
  final List<String> memberIds;
  final List<String> adminIds;
  final Message? lastMessage;
  final int unread;
  final int online;
  final List<String> archived; // userIds ayant archivé cette conversation
  final List<String> pinned; // userIds ayant épinglé cette conversation
  final List<String> deletedFor; // userIds ayant supprimé la discussion pour eux
  final Map<String, int> mutes; // userId -> expiration de la sourdine (epoch ms)
  final Map<String, NotifPrefs>
      notifs; // userId -> préférences de notification

  bool get isGroup => type == 'group';

  /// true si [userId] a archivé cette conversation.
  bool archivedFor(String userId) => archived.contains(userId);

  /// true si [userId] a épinglé cette conversation.
  bool pinnedFor(String userId) => pinned.contains(userId);

  /// true si [userId] a supprimé la discussion (pour lui).
  bool deletedForUser(String userId) => deletedFor.contains(userId);

  /// true si la sourdine de [userId] est active (expiration future).
  bool mutedFor(String userId, [int? nowMs]) {
    final until = mutes[userId];
    if (until == null) return false;
    return until > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  /// Préférences de notification de [userId] (null = défauts de l'app).
  NotifPrefs? notifsFor(String userId) => notifs[userId];

  Chat copyWith({
    String? name,
    List<String>? archived,
    List<String>? pinned,
    List<String>? deletedFor,
    Map<String, int>? mutes,
    Map<String, NotifPrefs>? notifs,
  }) =>
      Chat(
        id: id,
        type: type,
        name: name ?? this.name,
        memberIds: memberIds,
        adminIds: adminIds,
        lastMessage: lastMessage,
        unread: unread,
        online: online,
        archived: archived ?? this.archived,
        pinned: pinned ?? this.pinned,
        deletedFor: deletedFor ?? this.deletedFor,
        mutes: mutes ?? this.mutes,
        notifs: notifs ?? this.notifs,
      );

  factory Chat.fromJson(Map<String, dynamic> json) => Chat(
        id: json['id'] as String,
        type: json['type'] as String,
        name: json['name'] as String,
        memberIds: (json['memberIds'] as List).cast<String>(),
        adminIds: (json['adminIds'] as List? ?? []).cast<String>(),
        archived: (json['archived'] as List? ?? []).cast<String>(),
        pinned: (json['pinned'] as List? ?? []).cast<String>(),
        deletedFor: (json['deletedFor'] as List? ?? []).cast<String>(),
        mutes: (json['mutes'] as Map? ?? {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        notifs: (json['notifs'] as Map? ?? {})
            .map((k, v) => MapEntry(k as String, NotifPrefs.fromJson(v as Map<String, dynamic>))),
        lastMessage: json['lastMessage'] == null
            ? null
            : Message.fromJson(json['lastMessage'] as Map<String, dynamic>),
        unread: json['unread'] as int? ?? 0,
        online: json['online'] as int? ?? 0,
      );
}

class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.type,
    this.text = '',
    this.media,
    required this.createdAt,
    this.edited = false,
    this.deleted = false,
    this.deletedFor = const [],
    this.reactions = const {},
    this.replyTo,
    this.readBy = const [],
    this.deliveredTo = const [],
    this.starredBy = const [],
  });

  final String id;
  final String chatId;
  final String senderId;
  final String type; // text, image, video, document, audio, voice, videonote, gif, sticker, contact, location, poll, event, call, system
  final String text;
  final Map<String, dynamic>? media;
  final int createdAt;
  final bool edited;
  final bool deleted;
  final List<String> deletedFor;
  final Map<String, List<String>> reactions;
  final String? replyTo;
  final List<String> readBy;
  final List<String> deliveredTo;
  final List<String> starredBy; // userIds ayant mis en favori

  bool starredFor(String userId) => starredBy.contains(userId);

  bool isMine(String me) => senderId == me;

  bool visibleTo(String me) => !deleted && !deletedFor.contains(me);

  String preview() {
    switch (type) {
      case 'voice':
        return '🎙 Message vocal';
      case 'image':
        return '📷 Photo';
      case 'video':
        return '🎥 Vidéo';
      case 'videoNote':
        return '🎥 Note vidéo';
      case 'document':
        return '📄 ${text.isNotEmpty ? text : 'Document'}';
      case 'gif':
        return 'GIF';
      case 'sticker':
        return 'Sticker';
      case 'contact':
        return '👤 Contact partagé';
      case 'location':
        return '📍 Localisation';
      case 'poll':
        return '📊 Sondage · ${text.isNotEmpty ? text : 'Votez !'}';
      case 'event':
        return '🎉 ${text.isNotEmpty ? text : 'Événement'}';
      case 'call':
        return '📞 ${text.isNotEmpty ? text : 'Appel'}';
      case 'system':
        return text;
      default:
        return text;
    }
  }

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        chatId: json['chatId'] as String,
        senderId: json['senderId'] as String,
        type: json['type'] as String,
        text: json['text'] as String? ?? '',
        media: json['media'] as Map<String, dynamic>?,
        createdAt: json['createdAt'] as int? ?? 0,
        edited: json['edited'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        deletedFor: (json['deletedFor'] as List? ?? []).cast<String>(),
        reactions: _reactionsFrom(json['reactions']),
        replyTo: json['replyTo'] as String?,
        readBy: (json['readBy'] as List? ?? []).cast<String>(),
        deliveredTo: (json['deliveredTo'] as List? ?? []).cast<String>(),
        starredBy: (json['starredBy'] as List? ?? []).cast<String>(),
      );

  static Map<String, List<String>> _reactionsFrom(dynamic raw) {
    if (raw is! Map) return {};
    return raw.map((k, v) =>
        MapEntry(k.toString(), (v as List).map((e) => e.toString()).toList()));
  }
}

/// Événement temps réel reçu via SSE.
class ServerEvent {
  const ServerEvent(this.type, this.data);
  final String type; // message, react, edit, delete, vote, read, pending
  final Map<String, dynamic> data;

  factory ServerEvent.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map) {
      return ServerEvent(json['type'] as String? ?? 'message', Map<String, dynamic>.from(data));
    }
    if (data is List) {
      return ServerEvent(json['type'] as String? ?? 'message', {'__list': data});
    }
    return ServerEvent(json['type'] as String? ?? 'message', <String, dynamic>{});
  }

  factory ServerEvent.parse(String type, String rawData) {
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is Map) {
        return ServerEvent(type, Map<String, dynamic>.from(decoded));
      }
      if (decoded is List) {
        // payload tableau (ex. evenement "pending") range sous "__list"
        return ServerEvent(type, {'__list': decoded});
      }
      return ServerEvent(type, <String, dynamic>{});
    } catch (_) {
      return ServerEvent(type, <String, dynamic>{});
    }
  }
}

extension MessageCopyWith on Message {
  Message copyWith({
    String? text,
    Map<String, dynamic>? media,
    bool? edited,
    bool? deleted,
    List<String>? deletedFor,
    Map<String, List<String>>? reactions,
    List<String>? readBy,
    List<String>? deliveredTo,
    List<String>? starredBy,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        type: type,
        text: text ?? this.text,
        media: media ?? this.media,
        createdAt: createdAt,
        edited: edited ?? this.edited,
        deleted: deleted ?? this.deleted,
        deletedFor: deletedFor ?? this.deletedFor,
        reactions: reactions ?? this.reactions,
        replyTo: replyTo,
        readBy: readBy ?? this.readBy,
        deliveredTo: deliveredTo ?? this.deliveredTo,
        starredBy: starredBy ?? this.starredBy,
      );
}
