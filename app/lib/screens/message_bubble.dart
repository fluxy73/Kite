import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../ui/avatar.dart';

/// Bulle de message : rendu par type + réactions + métadonnées.
class KiteMessageBubble extends StatelessWidget {
  const KiteMessageBubble({
    super.key,
    required this.message,
    required this.chat,
    required this.meId,
    required this.senderName,
    required this.replyPreview,
    required this.isPlaying,
    this.voiceProgress = 0,
    required this.onLongPress,
    required this.onReact,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
    required this.onVote,
    required this.onVoicePlay,
    required this.onEventRsvp,
    required this.onOpenMedia,
    required this.rsvpYes,
    required this.rsvpMaybe,
    this.translation,
  });

  final Message message;
  final Chat chat;
  final String meId;
  final String senderName;
  final Message? replyPreview;
  final bool isPlaying;

  /// Progression de lecture du vocal (0..1) — position réelle du fichier.
  final double voiceProgress;
  final VoidCallback onLongPress;
  final void Function(String emoji) onReact;
  final VoidCallback onReply;
  final VoidCallback onEdit;
  final void Function(String mode) onDelete;
  final void Function(int index) onVote;
  final VoidCallback onVoicePlay;
  final void Function(String choice) onEventRsvp;
  final VoidCallback onOpenMedia;
  final bool rsvpYes;
  final bool rsvpMaybe;

  /// Traduction affichée sous la bulle (null = aucune, '…' = en cours).
  final String? translation;

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.type == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: KiteColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: KiteColors.border),
            ),
            child: Text(m.text,
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: KiteColors.muted, fontSize: 11.5)),
          ),
        ),
      );
    }

    final mine = m.isMine(meId);
    final bubbleColor = mine
        ? Color.lerp(KiteColors.surface2, KiteColors.accent, 0.14)!
        : KiteColors.surface;
    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!mine && chat.isGroup)
              Padding(
                padding: const EdgeInsets.only(left: 14, bottom: 2),
                child: Text(senderName,
                    style:  TextStyle(
                        color: KiteColors.tint2,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            if (replyPreview != null)
              Padding(
                padding: EdgeInsets.only(
                    left: mine ? 0 : 14, right: mine ? 14 : 0, bottom: 3),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 220),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    border:  Border(
                        left: BorderSide(color: KiteColors.accent, width: 2.5)),
                    color: KiteColors.fg.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_name(replyPreview!.senderId),
                          style:  TextStyle(
                              color: KiteColors.accent,
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5)),
                      Text(replyPreview!.preview(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:  TextStyle(
                              color: KiteColors.muted, fontSize: 12.5)),
                    ],
                  ),
                ),
              ),
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(mine ? 20 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 20),
                ),
                border: Border.all(
                  color: mine
                      ? KiteColors.accent.withValues(alpha: 0.3)
                      : KiteColors.border,
                ),
              ),
              child: _content(context, m),
            ),
            if (translation != null)
              Padding(
                padding: EdgeInsets.only(
                    left: mine ? 0 : 8, right: mine ? 8 : 0, top: 3),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: KiteColors.tint2.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: KiteColors.tint2.withValues(alpha: 0.3)),
                  ),
                  child: translation == '…'
                      ?  Row(mainAxisSize: MainAxisSize.min, children: [
                          const SizedBox(
                              width: 10,
                              height: 10,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.6)),
                          const SizedBox(width: 8),
                          Text('Traduction…',
                              style: TextStyle(
                                  color: KiteColors.muted, fontSize: 12)),
                        ])
                      : Text(translation!,
                          style:  TextStyle(
                              color: KiteColors.fg,
                              fontSize: 13,
                              height: 1.35,
                              fontStyle: FontStyle.italic)),
                ),
              ),
            if (m.reactions.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(
                    left: mine ? 0 : 8, right: mine ? 8 : 0, top: 3),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final e in m.reactions.entries)
                      KiteReactionChip(
                        emoji: e.key,
                        count: e.value.length,
                        mine: e.value.contains(meId),
                        onTap: () => onReact(e.key),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_time(m.createdAt)}${m.edited ? ' · modifié' : ''}',
                    style:  TextStyle(
                        color: KiteColors.muted,
                        fontSize: 10,
                        fontFamilyFallback: const ['monospace']),
                  ),
                  if (m.expiresAt != null) ...[
                    const SizedBox(width: 3),
                     Icon(Icons.timer_outlined,
                        size: 11, color: KiteColors.muted),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _name(String id) => id == meId ? 'Vous' : senderName;

  static String _time(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _content(BuildContext context, Message m) {
    switch (m.type) {
      case 'voice':
        return _voice(context, m);
      case 'image':
      case 'video':
      case 'gif':
      case 'videoNote':
        return _media(m);
      case 'document':
        return _document(m);
      case 'poll':
        return _poll(m);
      case 'event':
        return _event(m);
      case 'contact':
        return _contact(m);
      case 'location':
        return _location(m);
      case 'call':
        return _call(m);
      default:
        return Text(
          m.text,
          style: const TextStyle(fontSize: 15, height: 1.4),
        );
    }
  }

  Widget _voice(BuildContext context, Message m) {
    final dur = (m.media?['duration'] as num?)?.toInt() ?? 10;
    final mm = (dur ~/ 60).toString();
    final ss = (dur % 60).toString().padLeft(2, '0');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: onVoicePlay,
          child: Container(
            width: 34,
            height: 34,
            decoration:  BoxDecoration(
                color: KiteColors.accent, shape: BoxShape.circle),
            child: Icon(isPlaying ? Icons.pause : Icons.play_arrow,
                size: 17, color: KiteColors.accentInk),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 140,
          height: 26,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 22; i++)
                Expanded(
                  child: Container(
                    height: (8 + (i * 7919) % 16).toDouble(),
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: KiteColors.accent.withValues(
                          alpha: i / 22 < voiceProgress ? 1.0 : 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('$mm:$ss',
            style:  TextStyle(
                color: KiteColors.muted,
                fontSize: 11,
                fontFamilyFallback: const ['monospace'])),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: KiteColors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child:  Text('1×',
              style: TextStyle(color: KiteColors.muted, fontSize: 10.5)),
        ),
      ],
    );
  }

  Widget _media(Message m) {
    final icon = switch (m.type) {
      'video' => Icons.videocam_outlined,
      'gif' => Icons.gif_box_outlined,
      'videoNote' => Icons.smart_display_outlined,
      _ => Icons.photo_outlined,
    };
    final label = switch (m.type) {
      'video' => 'Vidéo',
      'gif' => 'GIF',
      'videoNote' => 'Note vidéo',
      _ => 'Photo',
    };
    return GestureDetector(
      onTap: onOpenMedia,
      child: Container(
        width: 232,
        height: 156,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              KiteColors.tint1.withValues(alpha: 0.3),
              KiteColors.tint2.withValues(alpha: 0.22),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 32, color: KiteColors.fg.withValues(alpha: 0.8)),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(fontSize: 12, color: KiteColors.muted)),
          ],
        ),
      ),
    );
  }

  Widget _document(Message m) {
    final ext = (m.media?['ext'] as String? ?? 'file').toUpperCase();
    final size = m.media?['size'] as String? ?? '—';
    final pages = m.media?['pages'];
    final meta = pages != null ? '$size · $pages pages' : size;
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: KiteColors.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(ext,
                    style:  TextStyle(
                        color: KiteColors.accent,
                        fontSize: 9,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Text(meta,
                        style:  TextStyle(
                            color: KiteColors.muted,
                            fontSize: 11,
                            fontFamilyFallback: const ['monospace'])),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onOpenMedia,
            child:  Text('Télécharger / Ouvrir',
                style: TextStyle(
                    color: KiteColors.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _poll(Message m) {
    final rawOptions = m.media?['options'] as List? ?? <Object>[];
    final rawVotes = m.media?['votes'] as List? ?? <Object>[];
    final voters = m.media?['voters'] as List? ?? <Object>[];
    final total = rawVotes.fold<int>(0, (sum, v) => sum + ((v as num).toInt()));
    final myVoted = voters.map((e) => e.toString()).contains(meId);
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.text.isNotEmpty ? m.text : 'Sondage',
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
          const SizedBox(height: 10),
          for (var i = 0; i < rawOptions.length; i++)
            InkWell(
              onTap: () => onVote(i),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.circle_outlined,
                      size: 16,
                      color: myVoted ? KiteColors.accent : KiteColors.muted,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 100,
                      child: Text(rawOptions[i].toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: total == 0
                              ? 0
                              : (rawVotes[i] as num).toInt() / total,
                          minHeight: 6,
                          backgroundColor: KiteColors.surface2,
                          color: KiteColors.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${(rawVotes[i] as num).toInt()}',
                        style:  TextStyle(
                            color: KiteColors.muted,
                            fontSize: 11,
                            fontFamilyFallback: const ['monospace'])),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$total votes${myVoted ? ' · vous avez voté' : ''}',
                  style:  TextStyle(
                      color: KiteColors.muted,
                      fontSize: 11,
                      fontFamilyFallback: const ['monospace'])),
               Text('Voir les votes',
                  style: TextStyle(color: KiteColors.accent, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _event(Message m) {
    final media = m.media;
    final participants = (media?['participants'] as num?)?.toInt() ?? 0;
    final maybe = (media?['maybe'] as num?)?.toInt() ?? 0;
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               Icon(Icons.celebration_outlined,
                  size: 17, color: KiteColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.text.isNotEmpty ? m.text : 'Événement',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${media?['date'] ?? ''} · ${media?['time'] ?? ''}',
              style:  TextStyle(
                  color: KiteColors.muted,
                  fontSize: 12,
                  fontFamilyFallback: const ['monospace'])),
          const SizedBox(height: 2),
          Text('📍 ${media?['location'] ?? ''}',
              style: TextStyle(color: KiteColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Text('$participants participants · $maybe peut-être',
              style: TextStyle(color: KiteColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: [
              _chip('Participer', on: rsvpYes, onTap: () => onEventRsvp('yes')),
              const SizedBox(width: 6),
              _chip('Peut-être',
                  on: rsvpMaybe, onTap: () => onEventRsvp('maybe')),
              const SizedBox(width: 6),
              _chip('Non', on: false, onTap: () {}),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, {required bool on, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: on
              ? KiteColors.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          border: Border.all(
            color: on
                ? KiteColors.accent.withValues(alpha: 0.5)
                : KiteColors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: on ? KiteColors.accent : KiteColors.fg)),
      ),
    );
  }

  Widget _contact(Message m) {
    final name = m.media?['name'] as String? ?? 'Contact';
    final phone = m.media?['phone'] as String? ?? '';
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              KiteAvatar(name: name, group: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    if (phone.isNotEmpty)
                      Text(phone,
                          style:  TextStyle(
                              color: KiteColors.muted,
                              fontSize: 12,
                              fontFamilyFallback: const ['monospace'])),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _chip('Voir le contact', on: false, onTap: onOpenMedia),
              const SizedBox(width: 6),
              _chip('Message', on: false, onTap: () {}),
            ],
          ),
        ],
      ),
    );
  }

  Widget _location(Message m) {
    final name = m.media?['name'] as String? ?? 'Localisation';
    return GestureDetector(
      onTap: onOpenMedia,
      child: SizedBox(
        width: 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              height: 110,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    KiteColors.tint3.withValues(alpha: 0.3),
                    KiteColors.tint1.withValues(alpha: 0.2)
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child:  Icon(Icons.location_on,
                  size: 34, color: KiteColors.accent),
            ),
            const SizedBox(height: 6),
            Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
             Text('Carte simulée · aucun GPS nécessaire',
                style: TextStyle(color: KiteColors.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _call(Message m) {
    final missed = m.text.contains('manqué');
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(missed ? Icons.call_missed : Icons.call,
                  size: 18,
                  color: missed ? KiteColors.danger : KiteColors.tint2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.text.isNotEmpty ? m.text : 'Appel',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _chip('Rappeler', on: false, onTap: onOpenMedia),
        ],
      ),
    );
  }
}

class KiteReactionChip extends StatelessWidget {
  const KiteReactionChip({
    super.key,
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });

  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: mine
              ? KiteColors.accent.withValues(alpha: 0.16)
              : KiteColors.surface,
          border: Border.all(
            color: mine
                ? KiteColors.accent.withValues(alpha: 0.5)
                : KiteColors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('$emoji $count', style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}

/// Formulaire de création de sondage (workflow simulé).
