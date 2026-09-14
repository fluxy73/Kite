import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../translation.dart';
import '../voice.dart';
import '../chat_lock.dart';
import 'chat_extras.dart';
import 'chat_info_sheet.dart';
import '../drafts.dart';
import '../formats.dart';
import '../message_notifier.dart';
import '../models.dart';
import '../people.dart';
import '../theme.dart';
import '../ui/ui.dart';
import '../voice_player.dart';
import 'message_menu.dart';
import 'message_bubble.dart';
import 'notif_defaults_screen.dart';
import 'voice_review_sheet.dart';

/// Conversation temps réel : tous les types de messages, réactions,
/// réponse, édition, suppression, pièces jointes (caméra, galerie,
/// documents, contacts — flux réels).
class ConversationScreen extends StatefulWidget {
  const ConversationScreen(
      {super.key, required this.api, required this.chat, this.translator});

  /// Injectable pour les tests ; [TranslationService] par défaut.
  final TranslationService? translator;

  final KiteApi api;
  final Chat chat;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  List<Message> _messages = [];
  bool _loading = true;
  String? _error;
  Message? _replyTo;
  Message? _editing;
  DateTime? _scheduleAt; // envoi programmé armé (null = envoi immédiat)
  bool _armingLock = false; // pose du verrou en cours (porte en mode setup)
  bool _lockBioAvailable = false; // capacité biométrique de l'appareil (option du réglage verrou)
  bool _isBlocked = false; // contact bloqué (DM)
  String _wallpaper = ''; // thème du chat (clé de palette)
  late final TranslationService _translator =
      widget.translator ?? TranslationService();
  final VoiceRecorder _voiceRecorder = VoiceRecorder();
  late final VoiceRecording _recording = VoiceRecording(_voiceRecorder);
  bool _micAvailable = true; // micro indisponible (desktop) -> envoi simulé
  final Map<String, String> _translations = {}; // messageId -> texte traduit
  StreamSubscription<ServerEvent>? _sse;

  // Indicateur de saisie distant (« Lucas écrit… »).
  String? _remoteTyping;
  Timer? _typingClear;
  Timer? _typingThrottle;

  // Lecture vocale (fichier réel, repli timeline simulée)
  final Map<String, VoicePlayer> _players = {};

  /// Ids de messages dont l'animation d'entrée a déjà été jouée — survit
  /// au recyclage des enfants de ListView.builder (pas de re-jeu au
  /// scroll-back). Appartient à l'écran, pas à la bulle.
  final Set<String> _entranceDone = {};
  // RSVP d'événements (state local)
  final Set<String> _rsvpYes = {};
  final Set<String> _rsvpMaybe = {};

  @override
  void initState() {
    super.initState();
    _probeLockBiometrics();
    _loadChatExtras();
    _probeMic();
    WidgetsBinding.instance.addObserver(this);

    _load();
    _sse = widget.api.realtime().listen(_onEvent, onError: (_) {});
    // Conversation ouverte : pas de popup de notification pour elle.
    MessageNotifier.instance.openChat(widget.chat.id);
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
    // Rebuild : sans lui, le morph micro↔envoi reste sur l'ancien état
    // (l'utilisateur tape puis déclenche un enregistrement au lieu d'envoyer).
    if (mounted) setState(() {});
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


  /// Sonde la capacité biométrique une seule fois (affichage de l'option).
  Future<void> _probeLockBiometrics() async {
    final ok = await LocalAuthAuthenticator().isAvailable();
    if (mounted && ok != _lockBioAvailable) {
      setState(() => _lockBioAvailable = ok);
    }
  }
  /// Vérifie une seule fois la disponibilité du micro (desktop sans micro).
  Future<void> _probeMic() async {
    final ok = await _voiceRecorder.hasPermission();
    if (mounted && ok != _micAvailable) {
      setState(() => _micAvailable = ok);
    }
  }

  /// Charge l'état « extras » de la fiche info : blocage (DM) et thème.
  Future<void> _loadChatExtras() async {
    try {
      final blocked = await widget.api.isBlocked(widget.chat.id);
      if (mounted && blocked != _isBlocked) {
        setState(() => _isBlocked = blocked);
      }
    } catch (_) {}
    if (mounted && widget.chat.wallpaper != _wallpaper) {
      setState(() => _wallpaper = widget.chat.wallpaper);
    }
  }

  /// Bascule le blocage du contact (DM) via l'API réelle.
  Future<void> _toggleBlock() async {
    try {
      await widget.api.setBlocked(widget.chat.id, blocked: !_isBlocked);
      if (!mounted) return;
      setState(() => _isBlocked = !_isBlocked);
      _toast(_isBlocked
          ? 'Contact bloqué — il ne peut plus vous écrire'
          : 'Contact débloqué');
    } catch (_) {
      _toast('Impossible de modifier le blocage');
    }
  }

  /// Applique le thème choisi (persisté, partagé par les membres).
  Future<void> _pickWallpaper() async {
    final key = await showWallpaperPicker(context, _wallpaper);
    if (key == null || !mounted) return;
    try {
      await widget.api.setChatWallpaper(widget.chat.id, key);
      if (!mounted) return;
      setState(() => _wallpaper = key);
      _toast(key.isEmpty ? 'Thème par défaut restauré' : 'Thème appliqué 🎨');
    } catch (_) {
      _toast("Impossible d'appliquer le thème");
    }
  }

  @override
  void dispose() {
    DraftStore.instance.flushIfNeeded(); // brouillon écrit sur disque
    MessageNotifier.instance.closeChat(widget.chat.id);
    _sse?.cancel();
    _recording.dispose();
    _typingClear?.cancel();
    _typingThrottle?.cancel();
    for (final p in _players.values) {
      p.dispose();
    }
    _voiceRecorder.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Re-verrouillage en quittant la conversation (comportement WhatsApp) :
    // le code sera redemandé à la prochaine ouverture.
    ChatLockStore.instance.lock(widget.chat.id);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retour au premier plan : toutes les conversations déverrouillées se
    // referment (app switcher, prêt du téléphone...).
    if (state == AppLifecycleState.resumed && mounted) {
      ChatLockStore.instance.lockAll();
      setState(() {});
    }
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
        // Sourdine active : aucun indicateur de saisie affiché.
        if (!widget.chat.mutedFor(widget.api.meId) &&
            data['chatId']?.toString() == widget.chat.id) {
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
              reac[k.toString()] =
                  (v as List).map((e) => e.toString()).toList();
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
          // Idempotent : l'écho temps réel peut suivre la mise à jour
          // optimiste déjà faite par _deleteMessage.
          return m.deletedFor.contains(widget.api.meId)
              ? m
              : m.copyWith(deletedFor: [...m.deletedFor, widget.api.meId]);
        });
      case 'expired':
        // Éphémères : le serveur (ou l'app locale) signale les messages disparus.
        final ids = (data['ids'] as List?)?.map((e) => e.toString()).toSet() ??
            const <String>{};
        setState(() {
          _messages.removeWhere((m) => ids.contains(m.id));
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
    KiteHaptics.send();
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
    final scheduleAt = _scheduleAt;
    if (scheduleAt != null) {
      try {
        await widget.api.scheduleMessage(
          widget.chat.id,
          text: text,
          scheduledAt: scheduleAt.millisecondsSinceEpoch,
          replyTo: _replyTo?.id,
        );
        setState(() {
          _input.clear();
          _replyTo = null;
          _scheduleAt = null;
        });
        _toast('Message programmé pour le ${_fmtSchedule(scheduleAt)}');
      } catch (e) {
        _toast('Échec de la programmation : $e');
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
      DraftStore.instance
          .clear(widget.chat.id); // envoi réussi : brouillon parti
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

  Future<void> _toggleRecording() async {
    if (_recording.active.value) {
      _stopRecording();
      return;
    }
    if (_micAvailable) {
      final ok = await _voiceRecorder.startWithStamp();
      if (!ok) {
        _toast('Micro indisponible — envoi simulé');
      }
    }
    KiteHaptics.recordStart();
    setState(_recording.start);
  }

  void _stopRecording() {
    setState(_recording.stop);
  }

  Future<void> _sendVoice() async {
    final dur = _recording.seconds.value;
    final bars = _recording.snapshotBars();
    _stopRecording();
    String? path;
    if (_micAvailable) {
      final rec = await _voiceRecorder.stop();
      if (rec != null) {
        (path, _) = rec;
      }
    }
    // Pré-écoute : pause, scrub, vitesse, abandon — avant transmission.
    if (path != null) {
      final ok = await _showVoiceReview(
          path: path, bars: bars, durationSec: dur < 1 ? 1 : dur);
      if (!ok) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        return;
      }
    }
    try {
      await widget.api.sendMessage(
        widget.chat.id,
        type: 'voice',
        media: {
          'duration': dur,
          if (path != null) 'path': path,
        },
      );
    } catch (e) {
      _toast('Vocal non envoyé : $e');
    }
  }

  /// Pré-écoute du vocal avant envoi : lecture/pause, scrub sur la
  /// waveform, vitesse 1x/1,5x/2x, abandon. Retourne true pour envoyer.
  Future<bool> _showVoiceReview({
    required String path,
    required List<double> bars,
    required int durationSec,
  }) async {
    final player = VoicePlayer();
    player.play(durationSec: durationSec, path: path);
    final ok = await showVoiceReviewSheet(
      context,
      player: player,
      bars: bars,
      durationSec: durationSec,
    );
    await player.hardStop();
    player.dispose();
    return ok;
  }

  // ---------- Actions message ----------

  Future<void> _react(Message m, String emoji) async {
    KiteHaptics.reactTick();
    try {
      await widget.api.toggleReaction(m.id, emoji);
    } catch (e) {
      _toast('Réaction impossible : $e');
    }
  }

  Future<void> _deleteMessage(Message m, String mode) async {
    try {
      await widget.api.deleteMessage(m.id, mode: mode);
      if (!mounted) return;
      setState(() {
        if (mode == 'all') {
          _messages.removeWhere((e) => e.id == m.id);
        } else {
          final idx = _messages.indexWhere((e) => e.id == m.id);
          if (idx >= 0) {
            _messages[idx] =
                _messages[idx].copyWith(deletedFor: [..._messages[idx].deletedFor, widget.api.meId]);
          }
        }
      });
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
    // Verrou de discussion : tant que la conversation n'est pas déverrouillée
    // (ou pendant la pose du code), aucun contenu n'est construit.
    final lockStore = ChatLockStore.instance;
    final isLocked = lockStore.isLocked(widget.chat.id);
    final needsGate =
        isLocked ? !lockStore.canOpen(widget.chat.id) : _armingLock;
    if (needsGate) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.chat.name),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (isLocked) {
                Navigator.of(context).maybePop();
              } else {
                setState(() => _armingLock = false); // annule la pose
              }
            },
          ),
        ),
        body: LockGate(
          chatId: widget.chat.id,
          chatName: widget.chat.name,
          mode: isLocked ? LockGateMode.unlock : LockGateMode.setup,
          onDone: () => setState(() {
            if (isLocked) {
              // déverrouillé : restore l'écran normal
            } else {
              _armingLock = false;
            }
          }),
        ),
      );
    }
    return Scaffold(
      appBar: _appBar(),
      body: Container(
        decoration: _wallpaper.isEmpty
            ? null
            : BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    kWallpapers[_wallpaper]!.start,
                    kWallpapers[_wallpaper]!.end,
                  ],
                ),
              ),
        child: Column(
          children: [
            if (_isBlocked)
              Material(
                color: Colors.redAccent.withValues(alpha: 0.15),
                child: InkWell(
                  onTap: _toggleBlock,
                  child: const ListTile(
                    dense: true,
                    leading: Icon(Icons.block, color: Colors.redAccent, size: 20),
                    title: Text('Contact bloqué — appuyez pour débloquer',
                        style: TextStyle(fontSize: 13, color: Colors.redAccent)),
                  ),
                ),
              ),
            Expanded(child: _messageList()),
            if (_isBlocked)
               Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                    'Vous avez bloqué ce contact. Débloquez-le pour lui écrire.',
                    style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
              )
            else
              _composerZone(),
          ],
        ),
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
          KiteAvatar(name: widget.chat.name, group: widget.chat.isGroup),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.chat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15),
                ),
                Text(
                  widget.chat.isGroup
                      ? '${widget.chat.memberIds.length} membres'
                      : (widget.chat.online > 0 ? 'en ligne' : 'vu il y a peu'),
                  style: TextStyle(color: KiteColors.muted, fontSize: 12),
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
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: _EphemeralPill(
              active: _disappearingOverride >= 0
                  ? _disappearingOverride > 0
                  : widget.chat.disappearing > 0,
              onTap: () => _showDisappearingPicker(context),
            ),
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

  /// Marque le message comme animé et retourne false au premier passage.
  bool _claimEntrance(String id) {
    if (_entranceDone.contains(id)) return false;
    _entranceDone.add(id);
    return true;
  }

  Widget _messageList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ListError(message: _error!, onRetry: _load);
    }
    final visible =
        _messages.where((m) => m.visibleTo(widget.api.meId)).toList();
    if (visible.isEmpty) {
      return const _NoMessages();
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      itemCount: visible.length,
      itemBuilder: (context, i) => MessageEntrance(
        animate: _claimEntrance(visible[i].id),
        child: SwipeToReply(
          onReply: () => _startReply(visible[i]),
          child: KiteMessageBubble(
        key: ValueKey(visible[i].id),
        message: visible[i],
        chat: widget.chat,
        meId: widget.api.meId,
        senderName: _senderName(visible[i].senderId),
        replyPreview: visible[i].replyTo == null
            ? null
            : _messages.where((m) => m.id == visible[i].replyTo).firstOrNull,
        isPlaying: _players[visible[i].id]?.playing.value ?? false,
        voiceProgress: _players[visible[i].id]?.progress.value ?? 0,
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
        translation: _translations[visible[i].id],
          ),
        ),
      ),
    );
  }

  void _toggleVoice(Message m) {
    final p = _players.putIfAbsent(m.id, () => VoicePlayer());
    setState(() {
      if (p.playing.value) {
        p.pause();
      } else {
        p.play(
          durationSec: (m.media?['duration'] as num?)?.toInt() ?? 10,
          path: m.media?['path'] as String?,
        );
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
    _toast(
        choice == 'yes' ? 'Vous participez 🎉' : 'Vous participez peut-être');
  }

  String _senderName(String id) => kiteDisplayName(id, widget.api.meId);

  // ---------- Composer ----------

  Widget _composerZone() {
    final canSend =
        _input.text.trim().isNotEmpty || _recording.active.value;
    return Container(
      decoration:  BoxDecoration(
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
                  style:
                      TextStyle(color: KiteColors.tint2, fontSize: 12)),
            ),
          if (_scheduleAt != null) _scheduleBar(),
          if (_replyTo != null) _replyBar(_replyTo!),
          if (_editing != null) _editBar(_editing!),
          if (_recording.active.value)
            _SpringReveal(child: _recordingBar())
          else
            Row(
              children: [
                KiteRoundBtn(
                  icon: Icons.add,
                  tooltip: 'Pièces jointes',
                  onTap: () => _showAttachments(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: KiteColors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: KiteColors.border),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 6),
                        Expanded(
                          child: Listener(
                            onPointerDown: (_) =>
                                HapticFeedback.selectionClick(),
                            child: TextField(
                              controller: _input,
                              focusNode: _inputFocus,
                              minLines: 1,
                              maxLines: 5,
                              onChanged: _onInputChanged,
                              onSubmitted: (_) => _send(),
                              style:  TextStyle(
                                  color: KiteColors.fg, height: 1.45),
                              decoration: InputDecoration(
                                hintText: _editing != null
                                    ? 'Modifier le message…'
                                    : 'Message…',
                                hintStyle:  TextStyle(
                                    color: KiteColors.muted),
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SpringMorph(
                  showSecond: canSend,
                  first: KiteRoundBtn(
                    icon: Icons.mic,
                    tooltip: 'Enregistrer un vocal',
                    onTap: _toggleRecording,
                  ),
                  second: KiteRoundBtn(
                    icon: _scheduleAt != null
                        ? Icons.schedule_send
                        : Icons.send,
                    tooltip:
                        _scheduleAt != null ? 'Programmer l\'envoi' : 'Envoyer',
                    accent: true,
                    onTap: _send,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Barre au-dessus du composer quand un envoi est programmé.
  Widget _scheduleBar() {
    final dt = _scheduleAt!;
    return _quoteBar(
      icon: Icons.schedule_send_outlined,
      title: 'Envoi programmé · ${_fmtSchedule(dt)}',
      preview: 'Le message partira automatiquement à cette date.',
      onClose: () => setState(() => _scheduleAt = null),
    );
  }

  String _fmtSchedule(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    const days = [
      'lundi',
      'mardi',
      'mercredi',
      'jeudi',
      'vendredi',
      'samedi',
      'dimanche'
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final hhmm = '${two(dt.hour)}:${two(dt.minute)}';
    if (day == today) return 'aujourd\'hui à $hhmm';
    if (day == today.add(const Duration(days: 1))) {
      return 'demain à $hhmm';
    }
    return '${days[dt.weekday - 1]} ${two(dt.day)}/${two(dt.month)} à $hhmm';
  }

  /// Sélecteur date + heure natif pour programmer l'envoi.
  Future<void> _pickSchedule() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Date d\'envoi',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: 'Heure d\'envoi',
    );
    if (time == null) return;
    final dt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!dt.isAfter(DateTime.now())) {
      _toast('Choisis une date/heure future.');
      return;
    }
    setState(() => _scheduleAt = dt);
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
        border:
            Border(left: BorderSide(color: KiteColors.accent, width: 3)),
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
                    style:  TextStyle(
                        color: KiteColors.accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5)),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(
                        color: KiteColors.muted, fontSize: 12.5)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: KiteColors.muted),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _recordingBar() {
    return ValueListenableBuilder<List<double>>(
      valueListenable: _recording.bars,
      builder: (context, bars, _) {
        return ValueListenableBuilder<int>(
          valueListenable: _recording.seconds,
          builder: (context, sec, _) {
            return ValueListenableBuilder<double>(
              valueListenable: _recording.liveAmp,
              builder: (context, amp, _) {
                return _recordingBarInner(bars, sec, amp);
              },
            );
          },
        );
      },
    );
  }

  Widget _recordingBarInner(List<double> bars, int recSec, double liveAmp) {
    final mm = (recSec ~/ 60).toString().padLeft(2, '0');
    final ss = (recSec % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        KiteRoundBtn(
            icon: Icons.delete_outline,
            tooltip: 'Annuler',
            onTap: _stopRecording),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: KiteColors.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: KiteColors.border),
              boxShadow: KiteColors.softShadow(),
            ),
            child: Row(
              children: [
                // Point d'enregistrement qui respire avec l'amplitude.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  width: 8 + liveAmp * 5,
                  height: 8 + liveAmp * 5,
                  decoration:  BoxDecoration(
                      color: KiteColors.ephemeral, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Text('$mm:$ss',
                    style:  TextStyle(
                        fontFamilyFallback: const ['monospace'],
                        color: KiteColors.fg)),
                const SizedBox(width: 12),
                Expanded(
                  child: CustomPaint(
                    size: const Size(double.infinity, 28),
                    painter: KiteWaveformPainter(
                      bars: bars,
                      progress: 1,
                      playedColor: KiteColors.accent,
                      pendingColor:
                          KiteColors.accent.withValues(alpha: 0.38),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        KiteRoundBtn(
            icon: Icons.send,
            tooltip: 'Envoyer le vocal',
            accent: true,
            onTap: _sendVoice),
      ],
    );
  }

  // ---------- Menu contextuel (appui long) ----------

  void _showMessageMenu(BuildContext context, Message m) {
    MessageMenu.show(
      context,
      m,
      meId: widget.api.meId,
      onReact: (e) => _react(m, e),
      onReply: () => _startReply(m),
      onCopy: () => _copyText(m.text),
      onEdit: () => _startEdit(m),
      onPin: () => _toast('Message épinglé 📌'),
      onToggleStar: () => _toggleStar(m),
      onTranslate: () => _translateMessage(m),
      onInfo: () => _showInfo(context, m),
      onDelete: (mode) => _confirmDelete(context, m, mode),
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

  /// Traduit un message (appui long -> Traduire) vers la langue de l'app
  /// (français). Le résultat s'affiche sous la bulle avec son texte d'origine.
  Future<void> _translateMessage(Message m) async {
    if (m.text.isEmpty) {
      _toast('Traduction possible pour les messages texte uniquement');
      return;
    }
    if (_translations.containsKey(m.id)) {
      setState(() => _translations.remove(m.id));
      return;
    }
    setState(() => _translations[m.id] = '…');
    try {
      final translated = await _translator.translate(m.text, 'fr');
      if (!mounted) return;
      setState(() => _translations[m.id] = translated);
    } on TranslationException catch (e) {
      if (!mounted) return;
      setState(() => _translations.remove(m.id));
      _toast('Traduction impossible : ${e.message}');
    }
  }

  /// Confirmation puis bascule du blocage.
  Future<void> _confirmBlock() async {
    if (_isBlocked) {
      await _toggleBlock();
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title:  Text('Bloquer ce contact ?',
            style: TextStyle(color: KiteColors.fg)),
        content:  Text(
            'Il ne pourra plus vous envoyer de messages. Vous pourrez le débloquer à tout moment.',
            style: TextStyle(color: KiteColors.muted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Bloquer'),
          ),
        ],
      ),
    );
    if (go == true && mounted) await _toggleBlock();
  }

  /// Dialogue de signalement puis envoi réel (serveur ou store local).
  Future<void> _reportChat() async {
    final result = await showReportDialog(context);
    if (result == null || !mounted) return;
    final (reason, details) = result;
    try {
      await widget.api.reportChat(widget.chat.id,
          reason: reason, details: details);
      _toast('Signalement envoyé — merci');
    } catch (_) {
      _toast("Impossible d'envoyer le signalement");
    }
  }

  void _copyText(String text) {
    // Clipboard via services — simple fallback snackbar.
    _toast(
        'Copié : « ${text.length > 30 ? '${text.substring(0, 30)}…' : text} »');
  }

  Future<void> _confirmDelete(BuildContext ctx, Message m, String mode) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: Text(mode == 'all'
            ? 'Supprimer pour tout le monde ?'
            : 'Supprimer pour moi ?'),
        content:  Text(
          'Cette action supprime le message du chat (simulation locale).',
          style: TextStyle(color: KiteColors.muted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, 'cancel'),
              child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, 'ok'),
            child:  Text('Supprimer',
                style: TextStyle(color: KiteColors.danger)),
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
    final hhmm = kiteHhmm(m.createdAt);
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
                 Text('Lu par',
                    style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
                for (final id in m.readBy.where((x) => x != m.senderId))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('• ${_senderName(id)}',
                        style: const TextStyle(fontSize: 14)),
                  ),
                const SizedBox(height: 8),
                 Text('Distribué à',
                    style: TextStyle(color: KiteColors.muted, fontSize: 12.5)),
                for (final id in m.deliveredTo)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('• ${_senderName(id)}',
                        style: const TextStyle(fontSize: 14)),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                  'Réactions : ${m.reactions.entries.map((e) => '${e.key} ${e.value.length}').join(' · ')}',
                  style:
                      TextStyle(color: KiteColors.muted, fontSize: 12.5)),
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
          Text(label, style: TextStyle(color: KiteColors.muted)),
          Text(value,
              style: const TextStyle(fontFamilyFallback: ['monospace'])),
        ],
      ),
    );
  }

  // ---------- Infos conversation ----------

  void _showChatInfo(BuildContext context) {
    ChatInfoSheet.show(
      context,
      chatName: widget.chat.name,
      isGroup: widget.chat.isGroup,
      memberIds: widget.chat.memberIds,
      adminIds: widget.chat.adminIds,
      chatId: widget.chat.id,
      disappearing: widget.chat.disappearing,
      senderName: _senderName,
      isBlocked: _isBlocked,
      lockBioAvailable: _lockBioAvailable,
      onMedia: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MediaGalleryScreen(
            messages: _messages,
            isMine: (m) => m.isMine(widget.api.meId),
            onOpen: (ctx, m) => Navigator.push(
              ctx,
              MaterialPageRoute(
                  builder: (_) => MediaViewerScreen(message: m)),
            ),
          ),
        ),
      ),
      onStarred: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MediaGalleryScreen(
            messages: _messages,
            isMine: (m) => m.isMine(widget.api.meId),
          ),
        ),
      ),
      onWallpaper: _pickWallpaper,
      onToggleBlock: _confirmBlock,
      onReport: _reportChat,
      onRemoveLock: _removeChatLock,
      onArmLock: () => setState(() => _armingLock = true),
      onToggleBiometrics: () {
        final on = !ChatLockStore.instance.biometricsFor(widget.chat.id);
        setState(
            () => ChatLockStore.instance.setBiometricsFor(widget.chat.id, on));
        _toast(on
            ? 'Biométrie activée pour cette discussion — code PIN en secours'
            : 'Biométrie désactivée pour cette discussion — code PIN uniquement');
      },
      onDisappearing: () => _showDisappearingPicker(context),
      onNotifications: _showNotifSettings,
    );
  }

  // ---------- Verrou de discussion ----------

  Future<void> _removeChatLock() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Retirer le verrou', style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          decoration: const InputDecoration(hintText: 'Code à 4 chiffres'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (ChatLockStore.instance.removeLock(widget.chat.id, controller.text)) {
      if (mounted) _toast('Verrou retiré');
    } else {
      if (mounted) _toast('Code incorrect — verrou toujours actif');
    }
  }

  // ---------- Verrou de discussion ----------

  // ---------- Messages éphémères (minuteur de conversation) ----------

  static const int _dm24h = 24 * 3600 * 1000;
  static const int _dm7d = 7 * 24 * 3600 * 1000;
  static const int _dm90d = 90 * 24 * 3600 * 1000;

  static String _disappearingLabel(int ms) => kiteDisappearingLabel(ms);

  int _disappearingOverride = -1; // -1 = suivre widget.chat

  Future<void> _showDisappearingPicker(BuildContext context) async {
    const options = <int, String>{
      0: 'Désactivé',
      _dm24h: '24 heures',
      _dm7d: '7 jours',
      _dm90d: '90 jours',
    };
    final current = _disappearingOverride >= 0
        ? _disappearingOverride
        : widget.chat.disappearing;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Messages éphémères', style: TextStyle(fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             Text(
              'Les nouveaux messages de cette conversation disparaissent après la durée choisie.',
              style: TextStyle(color: KiteColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            RadioGroup<int>(
              groupValue: current,
              onChanged: (v) => Navigator.pop(ctx, v),
              child: Column(
                children: [
                  for (final e in options.entries)
                    RadioListTile<int>(
                      value: e.key,
                      title:
                          Text(e.value, style: const TextStyle(fontSize: 14.5)),
                      activeColor: KiteColors.accent,
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await widget.api.setChatDisappearing(widget.chat.id, picked);
      if (!mounted) return;
      _toast(picked == 0
          ? 'Messages éphémères désactivés'
          : 'Messages éphémères : ${_disappearingLabel(picked)}');
      setState(() {
        _disappearingOverride = picked;
      });
    } catch (e) {
      if (mounted) _toast('Échec : $e');
    }
  }

  // ---------- Préférences de notification (priorité, son, aperçu) ----------

  Future<void> _showNotifSettings() async {
    final me = widget.api.meId;
    NotifPrefs prefs = widget.chat.notifsFor(me) ?? const NotifPrefs();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          backgroundColor: KiteColors.surface,
          title: const Text('Notifications'),
          content: SingleChildScrollView(
            child: NotifPrefsEditor(
              prefs: prefs,
              onChanged: (p) => setDialogState(() => prefs = p),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    try {
      await widget.api.setChatNotifs(
        widget.chat.id,
        prefs: prefs.isEmpty ? null : prefs,
      );
      _toast(prefs.isEmpty
          ? 'Préférences réinitialisées'
          : 'Préférences enregistrées');
    } catch (_) {
      _toast('Enregistrement impossible');
    }
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
              child: Text('Pièces jointes',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              mainAxisSpacing: 14,
              children: [
                _attachItem(sheetCtx, Icons.description_outlined, 'Document',
                    () => _pickDocument()),
                _attachItem(sheetCtx, Icons.photo_camera_outlined, 'Caméra',
                    () => _pickCamera()),
                _attachItem(sheetCtx, Icons.photo_library_outlined, 'Galerie',
                    () => _pickGallery()),
                _attachItem(sheetCtx, Icons.location_on_outlined,
                    'Localisation', () => _mockLocation(sheetCtx)),
                _attachItem(sheetCtx, Icons.person_outline, 'Contact',
                    () => _pickContact(sheetCtx)),
                _attachItem(sheetCtx, Icons.poll_outlined, 'Sondage',
                    () => _mockPoll(sheetCtx)),
                _attachItem(sheetCtx, Icons.event_outlined, 'Événement',
                    () => _mockEvent(sheetCtx)),
                _attachItem(
                    sheetCtx, Icons.schedule_send_outlined, 'Programmer', () {
                  Navigator.pop(sheetCtx);
                  _pickSchedule();
                }),
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
          Text(label,
              style: TextStyle(color: KiteColors.muted, fontSize: 10.5)),
        ],
      ),
    );
  }

  // ---------- Pièces jointes réelles ----------

  /// Chemin (absolu) -> nom de fichier court.
  String _fileName(String path) =>
      path.split(Platform.pathSeparator).last.split('/').last;

  /// Taille lisible d'un fichier, ou null s'il est introuvable.
  String? _fileSize(String path) {
    try {
      final bytes = File(path).lengthSync();
      if (bytes < 1024) return '$bytes o';
      if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} Ko';
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickDocument() async {
    final files = await FilePicker.pickFiles();
    final path = files.isEmpty ? null : files.first.path;
    if (path == null) return;
    await _sendMedia('document', _fileName(path), {
      'path': path,
      if (_fileSize(path) case final size?) 'size': size,
    });
    _toast('Document envoyé 📄');
  }

  Future<void> _pickCamera() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1920);
    if (picked == null) return;
    await _sendMedia('image', '', {'path': picked.path});
    _toast('Photo envoyée 📷');
  }

  Future<void> _pickGallery() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1920);
    if (picked == null) return;
    await _sendMedia('image', '', {'path': picked.path});
    _toast('Photo envoyée 🖼️');
  }

  Future<void> _sendMedia(String type, String text,
      [Map<String, dynamic>? media]) async {
    try {
      await widget.api
          .sendMessage(widget.chat.id, type: type, text: text, media: media);
    } catch (e) {
      _toast('Envoi impossible : $e');
    }
  }

  Future<void> _mockLocation(BuildContext ctx) async {
    // Position GPS réelle : permission -> service -> fix. Chaque échec est
    // expliqué, rien n'est simulé.
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      _toast('Permission de localisation refusée');
      return;
    }
    if (perm == LocationPermission.deniedForever) {
      _toast('Permission refusée définitivement — réglages de l app');
      await Geolocator.openAppSettings();
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      _toast('Service de localisation désactivé');
      await Geolocator.openLocationSettings();
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.medium));
      await _sendMedia('location', '', {
        'name': 'Position actuelle',
        'lat': pos.latitude,
        'lon': pos.longitude,
        if (pos.accuracy case final acc) 'accuracy': acc.round(),
      });
      _toast('Position partagée 📍');
    } catch (e) {
      _toast('Position indisponible : $e');
    }
  }

  Future<void> _pickContact(BuildContext ctx) async {
    if (!await FlutterContacts.requestPermission()) {
      _toast('Permission contacts refusée');
      return;
    }
    try {
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      if (!ctx.mounted) return;
      final picked = await showModalBottomSheet<_SharedContact>(
        context: ctx,
        builder: (_) => _ContactPickerSheet(contacts: contacts),
      );
      if (picked == null) return;
      await _sendMedia('contact', '',
          {'name': picked.name, if (picked.phone != null) 'phone': picked.phone});
      _toast('Contact partagé 👤');
    } catch (e) {
      _toast('Contacts indisponibles : $e');
    }
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

/// Lecteur vocal : lecture réelle du fichier (.m4a via just_audio) quand un
/// Bascule micro ↔ envoi : crossfade + échelle pilotés par le ressort
/// commun (pas de durée fixe). Les deux enfants restent dans l'arbre ;
/// seul le côté actif est touchable (dès le flip d'état, pas à mi-chemin).
class _SpringMorph extends StatefulWidget {
  const _SpringMorph({
    required this.showSecond,
    required this.first,
    required this.second,
  });

  final bool showSecond;
  final Widget first;
  final Widget second;

  @override
  State<_SpringMorph> createState() => _SpringMorphState();
}

class _SpringMorphState extends State<_SpringMorph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this)
    ..value = widget.showSecond ? 1 : 0;

  @override
  void didUpdateWidget(_SpringMorph old) {
    super.didUpdateWidget(old);
    if (old.showSecond != widget.showSecond) {
      animateWithSpring(
        _c,
        from: _c.value,
        to: widget.showSecond ? 1 : 0,
        spring: kKiteSpring,
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final v = _c.value.clamp(0.0, 1.0);
        return SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            children: [
              IgnorePointer(
                ignoring: widget.showSecond,
                child: Opacity(
                  opacity: 1 - v,
                  child: Transform.scale(
                      scale: 1 - 0.35 * v, child: widget.first),
                ),
              ),
              IgnorePointer(
                ignoring: !widget.showSecond,
                child: Opacity(
                  opacity: v,
                  child: Transform.scale(
                      scale: 0.65 + 0.35 * v, child: widget.second),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Apparition en expansion : la barre s'ouvre verticalement (heightFactor)
/// avec le ressort commun — la « poche » du dictaphone se déploie.
class _SpringReveal extends StatefulWidget {
  const _SpringReveal({required this.child});

  final Widget child;

  @override
  State<_SpringReveal> createState() => _SpringRevealState();
}

class _SpringRevealState extends State<_SpringReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    animateWithSpring(_c);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value.clamp(0.0, 1.0);
        return Align(
          heightFactor: v,
          alignment: Alignment.bottomCenter,
          child: Opacity(opacity: _fade.value.clamp(0.0, 1.0), child: child),
        );
      },
      child: widget.child,
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
            Icon(Icons.cloud_off, size: 44, color: KiteColors.danger),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: KiteColors.muted)),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: KiteColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: KiteColors.border),
                boxShadow: KiteColors.softShadow(),
              ),
              child:  Icon(Icons.forum_outlined,
                  size: 30, color: KiteColors.accent),
            ),
            const SizedBox(height: 14),
             Text('Cette conversation est privée.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: KiteColors.fg,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
             Text(
                'Écrivez le premier mot — tout reste entre vous.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: KiteColors.muted,
                    fontSize: 12.5,
                    height: 1.4)),
            const SizedBox(height: 12),
            // Carte d'inspection : le détail technique reste disponible,
            // sans jargon sur la surface principale.
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child:  ExpansionTile(
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding:
                    const EdgeInsets.fromLTRB(12, 0, 12, 10),
                backgroundColor: Colors.transparent,
                collapsedBackgroundColor: Colors.transparent,
                iconColor: KiteColors.muted,
                collapsedIconColor: KiteColors.muted,
                title: Text('Détails techniques',
                    style: TextStyle(
                        color: KiteColors.muted, fontSize: 12)),
                children: [
                  Text(
                    'Les messages sont chiffrés de bout en bout.\n'
                    'Personne en dehors de cette conversation '
                    'ne peut les lire.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: KiteColors.muted,
                        fontSize: 12,
                        height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
                onPressed: () =>
                    setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ajouter une option'),
              ),
            ),
            CheckboxListTile(
              value: _multi,
              onChanged: (v) => setState(() => _multi = v ?? false),
              title: const Text('Autoriser plusieurs réponses',
                  style: TextStyle(fontSize: 14)),
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
            final options = _options
                .map((c) => c.text.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            if (question.isEmpty || options.length < 2) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Question + au moins 2 options requises')),
              );
              return;
            }
            Navigator.pop(context,
                {'question': question, 'options': options, 'multi': _multi});
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
            TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Nom')),
            const SizedBox(height: 8),
            TextField(
                controller: _date,
                decoration:
                    const InputDecoration(hintText: 'Date (ex. 12 septembre)')),
            const SizedBox(height: 8),
            TextField(
                controller: _time,
                decoration:
                    const InputDecoration(hintText: 'Heure (ex. 18:30)')),
            const SizedBox(height: 8),
            TextField(
                controller: _location,
                decoration: const InputDecoration(hintText: 'Lieu')),
            const SizedBox(height: 8),
            TextField(
                controller: _link,
                decoration: const InputDecoration(
                    hintText: 'Lien d’appel (optionnel)')),
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

/// Pilule éphémère (app bar) : bascule permanente ↔ éphémère en un appui.
/// Teinte terracotta quand les messages s'effacent, neutre sinon.
class _EphemeralPill extends StatelessWidget {
  const _EphemeralPill({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SpringScale(
      onTap: onTap,
      pressedScale: 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? KiteColors.ephemeral.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? KiteColors.ephemeral.withValues(alpha: 0.55)
                : KiteColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.timer_outlined,
              size: 15,
              color: active ? KiteColors.ephemeral : KiteColors.muted,
            ),
            const SizedBox(width: 4),
            Text(
              active ? 'Éphémère' : 'Permanent',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: active ? KiteColors.ephemeral : KiteColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Contact choisi dans la feuille de partage (nom + téléphone principal).
class _SharedContact {
  const _SharedContact(this.name, this.phone);
  final String name;
  final String? phone;
}

/// Feuille de sélection d'un contact de l'appareil à partager.
class _ContactPickerSheet extends StatelessWidget {
  const _ContactPickerSheet({required this.contacts});

  final List<Contact> contacts;

  @override
  Widget build(BuildContext context) {
    final withPhone =
        contacts.where((c) => c.phones.isNotEmpty).toList();
    return SafeArea(
      child: SizedBox(
        height: 420,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Partager un contact',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            ),
            Expanded(
              child: withPhone.isEmpty
                  ? const Center(
                      child: Text('Aucun contact avec numéro de téléphone'))
                  : ListView.builder(
                      itemCount: withPhone.length,
                      itemBuilder: (_, i) {
                        final c = withPhone[i];
                        return ListTile(
                          leading: KiteAvatar(name: c.displayName, group: false),
                          title: Text(c.displayName),
                          subtitle: Text(c.phones.first.number),
                          onTap: () => Navigator.pop(
                            context,
                            _SharedContact(
                                c.displayName, c.phones.first.number),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
