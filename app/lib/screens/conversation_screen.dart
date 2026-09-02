import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../drafts.dart';
import '../models.dart';
import '../theme.dart';

/// Conversation temps réel : tous les types de messages, réactions,
/// réponse, édition, suppression, pièces jointes (workflows simulés).
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.api, required this.chat});

  final KiteApi api;
  final Chat chat;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Message> _messages = [];
  bool _loading = true;
  String? _error;
  Message? _replyTo;
  Message? _editing;
  StreamSubscription<ServerEvent>? _sse;

  // Indicateur de saisie distant (« Lucas écrit… »).
  String? _remoteTyping;
  Timer? _typingClear;
  Timer? _typingThrottle;

  // Enregistrement vocal simulé
  bool _recording = false;
  int _recSec = 0;
  Timer? _recTimer;

  // Lecture vocale simulée
  final Map<String, _VoicePlayer> _players = {};
  // RSVP d'événements (state local)
  final Set<String> _rsvpYes = {};
  final Set<String> _rsvpMaybe = {};

  @override
  void initState() {
    super.initState();

    _load();
    _sse = widget.api.realtime().listen(_onEvent, onError: (_) {});
    _loadDraft();
  }

  Future<void> _loadDraft() async {
    final d = DraftStore.instance.load(widget.chat.id);
    if (d.isNotEmpty && mounted) {
      setState(() => _input.text = d);
    }
  }

  void _onInputChanged(String text) {
    DraftStore.instance.save(widget.chat.id, text);
    // Indicateur de saisie : au plus 1 signal toutes les 3 s.
    if (text.trim().isNotEmpty &&
        (_typingThrottle == null || !_typingThrottle!.isActive)) {
      _typingThrottle = Timer(const Duration(seconds: 3), () {});
      widget.api.sendTyping(widget.chat.id).catchError((_) => null);
    }
  }

  void _showRemoteTyping(String name) {
    if (!mounted) return;
    setState(() => _remoteTyping = name);
    _typingClear?.cancel();
    _typingClear = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _remoteTyping = null);
    });
  }

  @override
  void dispose() {
    DraftStore.instance.flushIfNeeded(); // brouillon écrit sur disque
    _sse?.cancel();
    _recTimer?.cancel();
    _typingClear?.cancel();
    _typingThrottle?.cancel();
    for (final p in _players.values) {
      p.dispose();
    }
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final msgs = await widget.api.fetchMessages(widget.chat.id);
      if (mounted) {
        setState(() {
          _messages = msgs;
          _loading = false;
        });
        _jumpToEnd();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  // ---------- Temps réel ----------

  void _onEvent(ServerEvent ev) {
    if (!mounted) return;
    final data = ev.data;
    switch (ev.type) {
      case 'typing':
        if (data['chatId']?.toString() == widget.chat.id) {
          _showRemoteTyping(data['name']?.toString() ?? 'Quelqu\u2019un');
        }
      case 'message':
        _upsert(Message.fromJson(data));
      case 'pending':
        final list = data['__list'];
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              _upsert(Message.fromJson(Map<String, dynamic>.from(e)));
            }
          }
        } else if (data['message'] is Map) {
          _upsert(Message.fromJson(data));
        }
      case 'react':
        _patch(data['id']?.toString(), (m) {
          final raw = data['reactions'];
          if (raw is Map) {
            final reac = <String, List<String>>{};
            raw.forEach((k, v) {
              reac[k.toString()] = (v as List).map((e) => e.toString()).toList();
            });
            return m.copyWith(reactions: reac);
          }
          return m;
        });
      case 'edit':
        _upsert(Message.fromJson(data));
      case 'vote':
        _patch(data['id']?.toString(), (m) {
          final media = data['media'];
          if (media is Map) {
            return m.copyWith(media: Map<String, dynamic>.from(media));
          }
          return m;
        });
      case 'delete':
        _patch(data['id']?.toString(), (m) {
          if (data['deleted'] == true) {
            return m.copyWith(deleted: true);
          }
          return m.copyWith(deletedFor: [...m.deletedFor, widget.api.meId]);
        });
      default:
        break;
    }
  }

  void _upsert(Message m) {
    setState(() {
      final i = _messages.indexWhere((x) => x.id == m.id);
      if (i >= 0) {
        _messages[i] = m;
      } else {
        _messages.add(m);
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
    });
    _jumpToEnd();
  }

  void _patch(String? id, Message Function(Message) fn) {
    if (id == null) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.id == id);
      if (i >= 0) {
        _messages[i] = fn(_messages[i]);
      }
    });
  }

  // ---------- Envoi / réponse / édition ----------

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    if (editing != null) {
      try {
        await widget.api.editMessage(editing.id, text);
        setState(() {
          _editing = null;
          _input.clear();
        });
      } catch (e) {
        _toast('Échec de la modification : $e');
      }
      return;
    }
    try {
      final replyId = _replyTo?.id;
      await widget.api.sendMessage(
        widget.chat.id,
        type: 'text',
        text: text,
        replyTo: replyId,
      );
      setState(() {
        _input.clear();
        _replyTo = null;
      });
      DraftStore.instance.clear(widget.chat.id); // envoi réussi : brouillon parti
    } catch (e) {
      _toast('Message non envoyé — réessayer ?\n$e');
    }
  }

  void _startReply(Message m) {
    setState(() {
      _replyTo = m;
      _editing = null;
    });
    _toast('Réponse à ${_senderName(m.senderId)}');
  }

  void _startEdit(Message m) {
    setState(() {
      _editing = m;
      _replyTo = null;
      _input.text = m.text;
      _input.selection = TextSelection.collapsed(offset: m.text.length);
    });
    _inputFocus.requestFocus();
  }

  final FocusNode _inputFocus = FocusNode();

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------- Vocal (enregistrement simulé) ----------

  void _toggleRecording() {
    if (_recording) {
      _stopRecording();
      return;
    }
    setState(() {
      _recording = true;
      _recSec = 0;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recSec++);
      }
    });
  }

  void _stopRecording() {
    _recTimer?.cancel();
    setState(() {
      _recording = false;
    });
  }

  Future<void> _sendVoice() async {
    final dur = _recSec;
    _stopRecording();
    try {
      await widget.api.sendMessage(
        widget.chat.id,
        type: 'voice',
        media: {'duration': dur},
      );
    } catch (e) {
      _toast('Vocal non envoyé : $e');
    }
  }

  // ---------- Actions message ----------

  Future<void> _react(Message m, String emoji) async {
    try {
      await widget.api.toggleReaction(m.id, emoji);
    } catch (e) {
      _toast('Réaction impossible : $e');
    }
  }

  Future<void> _deleteMessage(Message m, String mode) async {
    try {
      await widget.api.deleteMessage(m.id, mode: mode);
    } catch (e) {
      _toast('Suppression impossible : $e');
    }
  }

  Future<void> _vote(Message m, int index) async {
    try {
      await widget.api.votePoll(m.id, index);
    } catch (e) {
      _toast('Vote impossible : $e');
    }
  }

  // ---------- Affichage ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: Column(
        children: [
          Expanded(child: _messageList()),
          _composerZone(),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: Row(
        children: [
          _MiniAvatar(name: widget.chat.name, group: widget.chat.isGroup),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.chat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                Text(
                  widget.chat.isGroup
                      ? '${widget.chat.memberIds.length} membres'
                      : (widget.chat.online > 0 ? 'en ligne' : 'vu il y a peu'),
                  style: const TextStyle(color: KiteColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Appel vidéo',
            onPressed: () => _toast('Appel vidéo — workflow simulé'),
          ),
          IconButton(
            icon: const Icon(Icons.call_outlined),
            tooltip: 'Appel vocal',
            onPressed: () => _toast('Appel vocal — workflow simulé'),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'Infos',
            onPressed: () => _showChatInfo(context),
          ),
        ],
      ),
    );
  }

  Widget _messageList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ListError(message: _error!, onRetry: _load);
    }
    final visible = _messages.where((m) => m.visibleTo(widget.api.meId)).toList();
    if (visible.isEmpty) {
      return const _NoMessages();
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: visible.length,
      itemBuilder: (context, i) => _MessageBubble(
        key: ValueKey(visible[i].id),
        message: visible[i],
        chat: widget.chat,
        meId: widget.api.meId,
        senderName: _senderName(visible[i].senderId),
        replyPreview: visible[i].replyTo == null
            ? null
            : _messages.where((m) => m.id == visible[i].replyTo).firstOrNull,
        isPlaying: _players[visible[i].id]?.playing.value ?? false,
        onLongPress: () => _showMessageMenu(context, visible[i]),
        onReact: (e) => _react(visible[i], e),
        onReply: () => _startReply(visible[i]),
        onEdit: () => _startEdit(visible[i]),
        onDelete: (mode) => _deleteMessage(visible[i], mode),
        onVote: (idx) => _vote(visible[i], idx),
        onVoicePlay: () => _toggleVoice(visible[i]),
        onEventRsvp: (choice) => _rsvp(visible[i], choice),
        onOpenMedia: () => _toast('Visionneuse média — workflow simulé'),
        rsvpYes: _rsvpYes.contains(visible[i].id),
        rsvpMaybe: _rsvpMaybe.contains(visible[i].id),
      ),
    );
  }

  void _toggleVoice(Message m) {
    final p = _players.putIfAbsent(m.id, () => _VoicePlayer());
    setState(() {
      if (p.playing.value) {
        p.pause();
      } else {
        p.play(durationSec: (m.media?['duration'] as num?)?.toInt() ?? 10);
      }
    });
  }

  void _rsvp(Message m, String choice) {
    setState(() {
      if (choice == 'yes') {
        if (_rsvpYes.contains(m.id)) {
          _rsvpYes.remove(m.id);
        } else {
          _rsvpYes.add(m.id);
          _rsvpMaybe.remove(m.id);
        }
      } else {
        if (_rsvpMaybe.contains(m.id)) {
          _rsvpMaybe.remove(m.id);
        } else {
          _rsvpMaybe.add(m.id);
          _rsvpYes.remove(m.id);
        }
      }
    });
    _toast(choice == 'yes' ? 'Vous participez 🎉' : 'Vous participez peut-être');
  }

  String _senderName(String id) {
    if (id == widget.api.meId) return 'Vous';
    if (id == 'u-lucas') return 'Lucas';
    if (id == 'u-emma') return 'Emma';
    if (id == 'u-thomas') return 'Thomas';
    if (id == 'u-sarah') return 'Sarah';
    return id;
  }

  // ---------- Composer ----------

  Widget _composerZone() {
    final canSend = _input.text.trim().isNotEmpty || _recording;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: KiteColors.border)),
        color: KiteColors.bg,
      ),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 10,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_remoteTyping != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 4),
              child: Text('✍ $_remoteTyping écrit…',
                  style: const TextStyle(color: KiteColors.tint2, fontSize: 12)),
            ),
          if (_replyTo != null) _replyBar(_replyTo!),
          if (_editing != null) _editBar(_editing!),
          if (_recording)
            _recordingBar()
          else
            Row(
              children: [
                _RoundBtn(
                  icon: Icons.add,
                  tooltip: 'Pièces jointes',
                  onTap: () => _showAttachments(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 5,
                    onChanged: _onInputChanged,
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(color: KiteColors.fg),
                    decoration: InputDecoration(
                      hintText: _editing != null ? 'Modifier le message…' : 'Message…',
                      hintStyle: const TextStyle(color: KiteColors.muted),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (canSend)
                  _RoundBtn(
                    icon: Icons.send,
                    tooltip: 'Envoyer',
                    accent: true,
                    onTap: _send,
                  )
                else
                  _RoundBtn(
                    icon: Icons.mic,
                    tooltip: 'Enregistrer un vocal',
                    onTap: _toggleRecording,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _replyBar(Message m) {
    return _quoteBar(
      icon: Icons.reply,
      title: 'Réponse à ${_senderName(m.senderId)}',
      preview: m.preview(),
      onClose: () => setState(() => _replyTo = null),
    );
  }

  Widget _editBar(Message m) {
    return _quoteBar(
      icon: Icons.edit_outlined,
      title: 'Modification',
      preview: m.preview(),
      onClose: () {
        setState(() {
          _editing = null;
          _input.clear();
        });
      },
    );
  }

  Widget _quoteBar({
    required IconData icon,
    required String title,
    required String preview,
    required VoidCallback onClose,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: KiteColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: const Border(left: BorderSide(color: KiteColors.accent, width: 3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: KiteColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KiteColors.accent, fontWeight: FontWeight.w600, fontSize: 12.5)),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KiteColors.muted, fontSize: 12.5)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: KiteColors.muted),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _recordingBar() {
    final mm = (_recSec ~/ 60).toString().padLeft(2, '0');
    final ss = (_recSec % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        _RoundBtn(icon: Icons.delete_outline, tooltip: 'Annuler', onTap: _stopRecording),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: KiteColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: KiteColors.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: KiteColors.danger, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Text('$mm:$ss', style: const TextStyle(fontFamilyFallback: ['monospace'], color: KiteColors.fg)),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [for (final h in [6, 14, 22, 10, 18, 24, 12, 16]) Container(width: 2.5, height: h.toDouble(), decoration: BoxDecoration(color: KiteColors.accent.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2)))],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _RoundBtn(icon: Icons.send, tooltip: 'Envoyer le vocal', accent: true, onTap: _sendVoice),
      ],
    );
  }

  // ---------- Menu contextuel (appui long) ----------

  void _showMessageMenu(BuildContext context, Message m) {
    final mine = m.isMine(widget.api.meId);
    final copyable = m.type == 'text';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final e in const ['❤️', '👍', '😂', '😮', '😢', '🙏'])
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        _react(m, e);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: KiteColors.border),
            _menuItem(sheetCtx, Icons.reply, 'Répondre', () => _startReply(m)),
            if (copyable) _menuItem(sheetCtx, Icons.copy_outlined, 'Copier', () => _copyText(m.text)),
            if (mine && copyable) _menuItem(sheetCtx, Icons.edit_outlined, 'Modifier', () => _startEdit(m)),
            _menuItem(sheetCtx, Icons.push_pin_outlined, 'Épingler', () => _toast('Message épinglé 📌')),
            _menuItem(
              sheetCtx,
              m.starredFor(widget.api.meId) ? Icons.star : Icons.star_border,
              m.starredFor(widget.api.meId) ? 'Retirer des favoris' : 'Ajouter aux favoris',
              () => _toggleStar(m),
            ),
            _menuItem(sheetCtx, Icons.info_outline, 'Informations', () => _showInfo(context, m)),
            _menuItem(
              sheetCtx,
              Icons.delete_outline,
              mine ? 'Supprimer pour tout le monde' : 'Supprimer pour moi',
              () => _confirmDelete(sheetCtx, m, mine ? 'all' : 'me'),
            ),
          ],
        ),
      ),
    );
  }

  /// Favori : appel l'API (serveur ou locale) et met à jour le message.
  Future<void> _toggleStar(Message m) async {
    try {
      final nowStarred = await widget.api.toggleStar(m.id);
      final idx = _messages.indexWhere((e) => e.id == m.id);
      if (idx >= 0 && mounted) {
        final starred = List<String>.from(_messages[idx].starredBy);
        setState(() {
          _messages[idx] = _messages[idx].copyWith(
            starredBy: nowStarred
                ? [...starred, widget.api.meId]
                : starred.where((u) => u != widget.api.meId).toList(),
          );
        });
      }
      _toast(nowStarred ? 'Ajouté aux favoris ⭐' : 'Retiré des favoris');
    } catch (_) {
      _toast('Action indisponible');
    }
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: label.startsWith('Supprimer') ? KiteColors.danger : KiteColors.accent),
      title: Text(
        label,
        style: TextStyle(color: label.startsWith('Supprimer') ? KiteColors.danger : KiteColors.fg),
      ),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  void _copyText(String text) {
    // Clipboard via services — simple fallback snackbar.
    _toast('Copié : « ${text.length > 30 ? '${text.substring(0, 30)}…' : text} »');
  }

  Future<void> _confirmDelete(BuildContext ctx, Message m, String mode) async {
    Navigator.pop(ctx);
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: Text(mode == 'all' ? 'Supprimer pour tout le monde ?' : 'Supprimer pour moi ?'),
        content: const Text(
          'Cette action supprime le message du chat (simulation locale).',
          style: TextStyle(color: KiteColors.muted),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, 'cancel'), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, 'ok'),
            child: const Text('Supprimer', style: TextStyle(color: KiteColors.danger)),
          ),
        ],
      ),
    );
    if (choice == 'ok') {
      await _deleteMessage(m, mode);
    }
  }

  // ---------- Informations message ----------

  void _showInfo(BuildContext sheetCtx, Message m) {
    final hhmm = _time(m.createdAt);
    showModalBottomSheet<void>(
      context: sheetCtx,
      backgroundColor: KiteColors.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Informations du message',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              if (m.isMine(widget.api.meId)) ...[
                _infoRow('Envoyé', hhmm),
                _infoRow('Distribué', m.deliveredTo.isNotEmpty ? hhmm : '—'),
                _infoRow('Lu', m.readBy.isNotEmpty ? hhmm : '—'),
              ],
              if (widget.chat.isGroup) ...[
                const SizedBox(height: 8),
                const Text('Lu par', style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
                for (final id in m.readBy.where((x) => x != m.senderId))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('• ${_senderName(id)}', style: const TextStyle(fontSize: 14)),
                  ),
                const SizedBox(height: 8),
                const Text('Distribué à', style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
                for (final id in m.deliveredTo)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('• ${_senderName(id)}', style: const TextStyle(fontSize: 14)),
                  ),
              ],
              const SizedBox(height: 12),
              Text('Réactions : ${m.reactions.entries.map((e) => '${e.key} ${e.value.length}').join(' · ')}',
                  style: const TextStyle(color: KiteColors.muted, fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: KiteColors.muted)),
          Text(value, style: const TextStyle(fontFamilyFallback: ['monospace'])),
        ],
      ),
    );
  }

  static String _time(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ---------- Infos conversation ----------

  void _showChatInfo(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _MiniAvatar(name: widget.chat.name, group: widget.chat.isGroup, large: true),
                  const SizedBox(height: 10),
                  Text(widget.chat.name,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  Text(
                    widget.chat.isGroup ? '${widget.chat.memberIds.length} membres' : 'en ligne',
                    style: const TextStyle(color: KiteColors.muted),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: KiteColors.border),
            if (widget.chat.isGroup)
              for (final id in widget.chat.memberIds)
                ListTile(
                  dense: true,
                  leading: _MiniAvatar(name: _senderName(id), group: false),
                  title: Text(_senderName(id)),
                  subtitle: widget.chat.adminIds.contains(id)
                      ? const Text('Admin', style: TextStyle(color: KiteColors.accent, fontSize: 11))
                      : null,
                ),
            for (final item in const ['Médias, liens et documents', 'Messages favoris', 'Notifications', 'Thème du chat', 'Verrouiller la discussion', 'Bloquer', 'Signaler'])
              ListTile(
                leading: const Icon(Icons.chevron_right, color: KiteColors.muted),
                title: Text(item, style: const TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _toast('$item — workflow simulé');
                },
              ),
          ],
        ),
      ),
    );
  }

  // ---------- Pièces jointes ----------

  void _showAttachments(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Pièces jointes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              mainAxisSpacing: 14,
              children: [
                _attachItem(sheetCtx, Icons.description_outlined, 'Document', () => _mockDocument(sheetCtx)),
                _attachItem(sheetCtx, Icons.photo_camera_outlined, 'Caméra', () => _mockCamera(sheetCtx)),
                _attachItem(sheetCtx, Icons.photo_library_outlined, 'Galerie', () => _mockGallery(sheetCtx)),
                _attachItem(sheetCtx, Icons.mic_none, 'Audio', () => _mockAudio(sheetCtx)),
                _attachItem(sheetCtx, Icons.location_on_outlined, 'Localisation', () => _mockLocation(sheetCtx)),
                _attachItem(sheetCtx, Icons.person_outline, 'Contact', () => _mockContact(sheetCtx)),
                _attachItem(sheetCtx, Icons.poll_outlined, 'Sondage', () => _mockPoll(sheetCtx)),
                _attachItem(sheetCtx, Icons.event_outlined, 'Événement', () => _mockEvent(sheetCtx)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachItem(
    BuildContext sheetCtx,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: () {
        Navigator.pop(sheetCtx);
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: KiteColors.surface2,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Icon(icon, color: KiteColors.accent, size: 22),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: KiteColors.muted, fontSize: 10.5)),
        ],
      ),
    );
  }

  // ---------- Workflows simulés de pièces jointes ----------

  Future<void> _sendMedia(String type, String text, [Map<String, dynamic>? media]) async {
    try {
      await widget.api.sendMessage(widget.chat.id, type: type, text: text, media: media);
    } catch (e) {
      _toast('Envoi impossible : $e');
    }
  }

  Future<void> _mockDocument(BuildContext ctx) async {
    final names = ['projet-final.pdf', 'specs.docx', 'budget.xlsx', 'presentation.pptx', 'archive.zip'];
    final name = names[DateTime.now().millisecond % names.length];
    final ext = name.split('.').last.toUpperCase();
    await _sendMedia('document', name, {'ext': ext, 'size': '7,8 Mo', 'pages': 24});
    _toast('Document envoyé 📄');
  }

  Future<void> _mockCamera(BuildContext ctx) async {
    await _sendMedia('image', '', {'name': 'IMG_capture.jpg'});
    _toast('Photo prise et envoyée 📷');
  }

  Future<void> _mockGallery(BuildContext ctx) async {
    await _sendMedia('image', '', {'name': 'IMG_album.jpg', 'album': 3});
    _toast('Album de 3 photos envoyé 🖼️');
  }

  Future<void> _mockAudio(BuildContext ctx) async {
    await _sendMedia('voice', '', {'duration': 12});
    _toast('Message audio envoyé 🎙️');
  }

  Future<void> _mockLocation(BuildContext ctx) async {
    await _sendMedia('location', '', {'name': 'Position actuelle', 'live': false});
    _toast('Localisation envoyée 📍');
  }

  Future<void> _mockContact(BuildContext ctx) async {
    await _sendMedia('contact', '', {'name': 'Lucas Martin', 'phone': '+33 6 12 34 56 78'});
    _toast('Contact partagé 👤');
  }

  Future<void> _mockPoll(BuildContext ctx) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _PollCreateDialog(),
    );
    if (result == null) return;
    final options = (result['options'] as List).cast<String>();
    final multi = result['multi'] == true;
    await _sendMedia('poll', result['question'] as String, {
      'options': options,
      'votes': List<int>.filled(options.length, 0),
      'voters': <String>[],
      'multi': multi,
    });
    _toast('Sondage envoyé 📊');
  }

  Future<void> _mockEvent(BuildContext ctx) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _EventCreateDialog(),
    );
    if (result == null) return;
    await _sendMedia('event', result['title'] as String, {
      'date': result['date'],
      'time': result['time'],
      'location': result['location'],
      'link': result['link'],
      'participants': 0,
      'maybe': 0,
    });
    _toast('Événement envoyé 🎉');
  }
}

// ═══════════════════════ Widgets de support ═══════════════════════

/// Lecteur vocal simulé : un timer fait progresser la timeline.
class _VoicePlayer {
  final ValueNotifier<double> progress = ValueNotifier(0);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  Timer? _t;
  int _total = 0;
  int _elapsed = 0;

  bool get isPlaying => playing.value;

  void play({required int durationSec}) {
    _total = durationSec;
    _elapsed = 0;
    playing.value = true;
    progress.value = 0;
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed++;
      if (_elapsed >= _total * 5) {
        pause();
        return;
      }
      progress.value = _elapsed / (_total * 5);
    });
  }

  void pause() {
    _t?.cancel();
    playing.value = false;
  }

  void dispose() {
    _t?.cancel();
    progress.dispose();
    playing.dispose();
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: accent ? KiteColors.accent : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 21,
          color: accent ? KiteColors.accentInk : KiteColors.muted,
        ),
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  const _MiniAvatar({required this.name, required this.group, this.large = false});

  final String name;
  final bool group;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final size = large ? 64.0 : 36.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(group ? size * 0.33 : size / 2),
        border: Border.all(color: KiteColors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: large ? 22 : 13),
      ),
    );
  }
}

class _ListError extends StatelessWidget {
  const _ListError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44, color: KiteColors.danger),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: KiteColors.muted)),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMessages extends StatelessWidget {
  const _NoMessages();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Les messages sont chiffrés de bout en bout.\nPersonne en dehors de cette conversation ne peut les lire.',
        textAlign: TextAlign.center,
        style: TextStyle(color: KiteColors.muted, fontSize: 12.5),
      ),
    );
  }
}

/// Bulle de message : rendu par type + réactions + métadonnées.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.chat,
    required this.meId,
    required this.senderName,
    required this.replyPreview,
    required this.isPlaying,
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
  });

  final Message message;
  final Chat chat;
  final String meId;
  final String senderName;
  final Message? replyPreview;
  final bool isPlaying;
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
                style: const TextStyle(color: KiteColors.muted, fontSize: 11.5)),
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
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!mine && chat.isGroup)
              Padding(
                padding: const EdgeInsets.only(left: 14, bottom: 2),
                child: Text(senderName,
                    style: const TextStyle(color: KiteColors.tint2, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            if (replyPreview != null)
              Padding(
                padding: EdgeInsets.only(left: mine ? 0 : 14, right: mine ? 14 : 0, bottom: 3),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 220),
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    border: const Border(left: BorderSide(color: KiteColors.accent, width: 2.5)),
                    color: KiteColors.fg.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_name(replyPreview!.senderId),
                          style: const TextStyle(color: KiteColors.accent, fontWeight: FontWeight.w600, fontSize: 12.5)),
                      Text(replyPreview!.preview(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: KiteColors.muted, fontSize: 12.5)),
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
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 6),
                  bottomRight: Radius.circular(mine ? 6 : 18),
                ),
                border: Border.all(
                  color: mine ? KiteColors.accent.withValues(alpha: 0.3) : KiteColors.border,
                ),
              ),
              child: _content(context, m),
            ),
            if (m.reactions.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(left: mine ? 0 : 8, right: mine ? 8 : 0, top: 3),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final e in m.reactions.entries)
                      _ReactionChip(
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
              child: Text(
                '${_time(m.createdAt)}${m.edited ? ' · modifié' : ''}',
                style: const TextStyle(color: KiteColors.muted, fontSize: 10, fontFamilyFallback: ['monospace']),
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
            decoration: const BoxDecoration(color: KiteColors.accent, shape: BoxShape.circle),
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
                      color: KiteColors.accent.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text('$mm:$ss', style: const TextStyle(color: KiteColors.muted, fontSize: 11, fontFamilyFallback: ['monospace'])),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: KiteColors.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text('1×', style: TextStyle(color: KiteColors.muted, fontSize: 10.5)),
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
            Text(label, style: const TextStyle(fontSize: 12, color: KiteColors.muted)),
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
                    style: const TextStyle(color: KiteColors.accent, fontSize: 9, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.text, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                    Text(meta, style: const TextStyle(color: KiteColors.muted, fontSize: 11, fontFamilyFallback: ['monospace'])),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: onOpenMedia,
            child: const Text('Télécharger / Ouvrir',
                style: TextStyle(color: KiteColors.accent, fontSize: 12.5, fontWeight: FontWeight.w600)),
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
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
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
                      child: Text(rawOptions[i].toString(), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: total == 0 ? 0 : (rawVotes[i] as num).toInt() / total,
                          minHeight: 6,
                          backgroundColor: KiteColors.surface2,
                          color: KiteColors.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${(rawVotes[i] as num).toInt()}',
                        style: const TextStyle(color: KiteColors.muted, fontSize: 11, fontFamilyFallback: ['monospace'])),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$total votes${myVoted ? ' · vous avez voté' : ''}',
                  style: const TextStyle(color: KiteColors.muted, fontSize: 11, fontFamilyFallback: ['monospace'])),
              const Text('Voir les votes', style: TextStyle(color: KiteColors.accent, fontSize: 11)),
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
              const Icon(Icons.celebration_outlined, size: 17, color: KiteColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.text.isNotEmpty ? m.text : 'Événement',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${media?['date'] ?? ''} · ${media?['time'] ?? ''}',
              style: const TextStyle(color: KiteColors.muted, fontSize: 12, fontFamilyFallback: ['monospace'])),
          const SizedBox(height: 2),
          Text('📍 ${media?['location'] ?? ''}',
              style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Text('$participants participants · $maybe peut-être',
              style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            children: [
              _chip('Participer', on: rsvpYes, onTap: () => onEventRsvp('yes')),
              const SizedBox(width: 6),
              _chip('Peut-être', on: rsvpMaybe, onTap: () => onEventRsvp('maybe')),
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
          color: on ? KiteColors.accent.withValues(alpha: 0.16) : Colors.transparent,
          border: Border.all(
            color: on ? KiteColors.accent.withValues(alpha: 0.5) : KiteColors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: on ? KiteColors.accent : KiteColors.fg)),
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
              _MiniAvatar(name: name, group: false),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    if (phone.isNotEmpty)
                      Text(phone, style: const TextStyle(color: KiteColors.muted, fontSize: 12, fontFamilyFallback: ['monospace'])),
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
                  colors: [KiteColors.tint3.withValues(alpha: 0.3), KiteColors.tint1.withValues(alpha: 0.2)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.location_on, size: 34, color: KiteColors.accent),
            ),
            const SizedBox(height: 6),
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Text('Carte simulée · aucun GPS nécessaire',
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
              Icon(missed ? Icons.call_missed : Icons.call, size: 18,
                  color: missed ? KiteColors.danger : KiteColors.tint2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(m.text.isNotEmpty ? m.text : 'Appel',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
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

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
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
          color: mine ? KiteColors.accent.withValues(alpha: 0.16) : KiteColors.surface,
          border: Border.all(
            color: mine ? KiteColors.accent.withValues(alpha: 0.5) : KiteColors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('$emoji $count', style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}

/// Formulaire de création de sondage (workflow simulé).
class _PollCreateDialog extends StatefulWidget {
  const _PollCreateDialog();

  @override
  State<_PollCreateDialog> createState() => _PollCreateDialogState();
}

class _PollCreateDialogState extends State<_PollCreateDialog> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multi = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: KiteColors.surface,
      title: const Text('Créer un sondage'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _question,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Question'),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _options[i],
                  decoration: InputDecoration(hintText: 'Option ${i + 1}'),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter une option'),
              ),
            ),
            CheckboxListTile(
              value: _multi,
              onChanged: (v) => setState(() => _multi = v ?? false),
              title: const Text('Autoriser plusieurs réponses', style: TextStyle(fontSize: 14)),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            final question = _question.text.trim();
            final options = _options.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
            if (question.isEmpty || options.length < 2) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Question + au moins 2 options requises')),
              );
              return;
            }
            Navigator.pop(context, {'question': question, 'options': options, 'multi': _multi});
          },
          child: const Text('Créer'),
        ),
      ],
    );
  }
}

/// Formulaire de création d'événement (workflow simulé).
class _EventCreateDialog extends StatefulWidget {
  const _EventCreateDialog();

  @override
  State<_EventCreateDialog> createState() => _EventCreateDialogState();
}

class _EventCreateDialogState extends State<_EventCreateDialog> {
  final _title = TextEditingController();
  final _date = TextEditingController();
  final _time = TextEditingController();
  final _location = TextEditingController();
  final _link = TextEditingController();

  @override
  void dispose() {
    for (final c in [_title, _date, _time, _location, _link]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: KiteColors.surface,
      title: const Text('Créer un événement'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _title, autofocus: true, decoration: const InputDecoration(hintText: 'Nom')),
            const SizedBox(height: 8),
            TextField(controller: _date, decoration: const InputDecoration(hintText: 'Date (ex. 12 septembre)')),
            const SizedBox(height: 8),
            TextField(controller: _time, decoration: const InputDecoration(hintText: 'Heure (ex. 18:30)')),
            const SizedBox(height: 8),
            TextField(controller: _location, decoration: const InputDecoration(hintText: 'Lieu')),
            const SizedBox(height: 8),
            TextField(controller: _link, decoration: const InputDecoration(hintText: 'Lien d’appel (optionnel)')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            if (title.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Nom de l’événement requis')),
              );
              return;
            }
            Navigator.pop(context, {
              'title': title,
              'date': _date.text.trim(),
              'time': _time.text.trim(),
              'location': _location.text.trim(),
              'link': _link.text.trim(),
            });
          },
          child: const Text('Créer'),
        ),
      ],
    );
  }
}
