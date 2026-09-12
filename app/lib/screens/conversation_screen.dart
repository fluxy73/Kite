import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../translation.dart';
import '../voice.dart';
import 'package:just_audio/just_audio.dart';
import '../chat_lock.dart';
import 'chat_extras.dart';
import '../drafts.dart';
import '../message_notifier.dart';
import '../models.dart';
import '../theme.dart';
import '../ui/ui.dart';
import 'notif_defaults_screen.dart';

/// Conversation temps réel : tous les types de messages, réactions,
/// réponse, édition, suppression, pièces jointes (workflows simulés).
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
  bool _micAvailable = true; // micro indisponible (desktop) -> envoi simulé
  final Map<String, String> _translations = {}; // messageId -> texte traduit
  StreamSubscription<ServerEvent>? _sse;

  // Indicateur de saisie distant (« Lucas écrit… »).
  String? _remoteTyping;
  Timer? _typingClear;
  Timer? _typingThrottle;

  // Enregistrement vocal (waveform = amplitudes réelles du micro)
  bool _recording = false;
  int _recSec = 0;
  Timer? _recTimer;
  StreamSubscription<dynamic>? _ampSub;
  final List<double> _amp = List.filled(34, 0.0);
  double _liveAmp = 0;

  // Lecture vocale simulée
  final Map<String, _VoicePlayer> _players = {};

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
    _recTimer?.cancel();
    _ampSub?.cancel();
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
          return m.copyWith(deletedFor: [...m.deletedFor, widget.api.meId]);
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
    if (_recording) {
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
    setState(() {
      _recording = true;
      _recSec = 0;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recSec++);
      }
    });
    // Waveform vivante : amplitudes réelles du micro (20 mesures/seconde,
    // 34 barres glissantes).
    _ampSub?.cancel();
    _ampSub = _voiceRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 50))
        .listen(
      (a) {
        if (!mounted) return;
        final norm = ((a.current + 50) / 50).clamp(0.0, 1.0);
        _amp
          ..removeAt(0)
          ..add(norm);
        _liveAmp = norm;
      },
      onError: (_) {},
    );
  }

  void _stopRecording() {
    _recTimer?.cancel();
    _ampSub?.cancel();
    _ampSub = null;
    setState(() {
      _recording = false;
    });
  }

  Future<void> _sendVoice() async {
    final dur = _recSec;
    final bars = List.of(_amp);
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
    final player = _VoicePlayer();
    player.play(durationSec: durationSec, path: path);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: _VoiceReviewSheet(player: player, bars: bars, durationSec: durationSec),
      ),
    ).then((v) => v ?? false);
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
          child: _MessageBubble(
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
    final p = _players.putIfAbsent(m.id, () => _VoicePlayer());
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
          if (_recording)
            _SpringReveal(child: _recordingBar())
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
                          child: PressableField(
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
                  first: _RoundBtn(
                    icon: Icons.mic,
                    tooltip: 'Enregistrer un vocal',
                    onTap: _toggleRecording,
                  ),
                  second: _RoundBtn(
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
    final mm = (_recSec ~/ 60).toString().padLeft(2, '0');
    final ss = (_recSec % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        _RoundBtn(
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
                  width: 8 + _liveAmp * 5,
                  height: 8 + _liveAmp * 5,
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
                    painter: _WaveformPainter(
                      bars: _amp,
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
        _RoundBtn(
            icon: Icons.send,
            tooltip: 'Envoyer le vocal',
            accent: true,
            onTap: _sendVoice),
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
        // Scrollable : le menu reste accessible même sur petit écran.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: SpringReactionBar(
                onPick: (e) {
                  Navigator.pop(sheetCtx);
                  _react(m, e);
                },
              ),
            ),
            Divider(height: 1, color: KiteColors.border),
            _menuItem(sheetCtx, Icons.reply, 'Répondre', () => _startReply(m)),
            if (copyable)
              _menuItem(sheetCtx, Icons.copy_outlined, 'Copier',
                  () => _copyText(m.text)),
            if (mine && copyable)
              _menuItem(sheetCtx, Icons.edit_outlined, 'Modifier',
                  () => _startEdit(m)),
            _menuItem(sheetCtx, Icons.push_pin_outlined, 'Épingler',
                () => _toast('Message épinglé 📌')),
            _menuItem(
              sheetCtx,
              m.starredFor(widget.api.meId) ? Icons.star : Icons.star_border,
              m.starredFor(widget.api.meId)
                  ? 'Retirer des favoris'
                  : 'Ajouter aux favoris',
              () => _toggleStar(m),
            ),
            _menuItem(sheetCtx, Icons.translate, 'Traduire',
                () => _translateMessage(m)),
            _menuItem(sheetCtx, Icons.info_outline, 'Informations',
                () => _showInfo(context, m)),
            _menuItem(
              sheetCtx,
              Icons.delete_outline,
              mine ? 'Supprimer pour tout le monde' : 'Supprimer pour moi',
              () => _confirmDelete(sheetCtx, m, mine ? 'all' : 'me'),
            ),
            ],
          ),
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

  Widget _menuItem(
      BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon,
          color: label.startsWith('Supprimer')
              ? KiteColors.danger
              : KiteColors.accent),
      title: Text(
        label,
        style: TextStyle(
            color: label.startsWith('Supprimer')
                ? KiteColors.danger
                : KiteColors.fg),
      ),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  void _copyText(String text) {
    // Clipboard via services — simple fallback snackbar.
    _toast(
        'Copié : « ${text.length > 30 ? '${text.substring(0, 30)}…' : text} »');
  }

  Future<void> _confirmDelete(BuildContext ctx, Message m, String mode) async {
    Navigator.pop(ctx);
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
                  _MiniAvatar(
                      name: widget.chat.name,
                      group: widget.chat.isGroup,
                      large: true),
                  const SizedBox(height: 10),
                  Text(widget.chat.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600)),
                  Text(
                    widget.chat.isGroup
                        ? '${widget.chat.memberIds.length} membres'
                        : 'en ligne',
                    style: TextStyle(color: KiteColors.muted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: KiteColors.border),
            if (widget.chat.isGroup)
              for (final id in widget.chat.memberIds)
                ListTile(
                  dense: true,
                  leading: _MiniAvatar(name: _senderName(id), group: false),
                  title: Text(_senderName(id)),
                  subtitle: widget.chat.adminIds.contains(id)
                      ?  Text('Admin',
                          style:
                              TextStyle(color: KiteColors.accent, fontSize: 11))
                      : null,
                ),
            ListTile(
              leading:  Icon(Icons.photo_library_outlined,
                  color: KiteColors.muted),
              title: const Text('Médias, liens et documents',
                  style: TextStyle(fontSize: 14.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(
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
                );
              },
            ),
            ListTile(
              leading:
                  Icon(Icons.star_border, color: KiteColors.muted),
              title: const Text('Messages favoris',
                  style: TextStyle(fontSize: 14.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MediaGalleryScreen(
                      messages: _messages,
                      isMine: (m) => m.isMine(widget.api.meId),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading:  Icon(Icons.palette_outlined,
                  color: KiteColors.muted),
              title: const Text('Thème du chat',
                  style: TextStyle(fontSize: 14.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _pickWallpaper();
              },
            ),
            if (!widget.chat.isGroup)
              ListTile(
                leading: Icon(
                    _isBlocked ? Icons.lock_person : Icons.block,
                    color: _isBlocked ? Colors.redAccent : KiteColors.muted),
                title: Text(_isBlocked ? 'Débloquer le contact' : 'Bloquer',
                    style: const TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmBlock();
                },
              ),
            ListTile(
              leading: Icon(Icons.flag_outlined, color: KiteColors.muted),
              title: const Text('Signaler', style: TextStyle(fontSize: 14.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _reportChat();
              },
            ),
            ListTile(
              leading: Icon(
                ChatLockStore.instance.isLocked(widget.chat.id)
                    ? Icons.lock
                    : Icons.lock_outline,
                color: ChatLockStore.instance.isLocked(widget.chat.id)
                    ? KiteColors.accent
                    : KiteColors.muted,
              ),
              title: Text(
                ChatLockStore.instance.isLocked(widget.chat.id)
                    ? 'Retirer le verrou de la discussion'
                    : 'Verrouiller la discussion',
                style: const TextStyle(fontSize: 14.5),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                if (ChatLockStore.instance.isLocked(widget.chat.id)) {
                  _removeChatLock();
                } else {
                  setState(() => _armingLock = true);
                }
              },
            ),
            if (_lockBioAvailable && ChatLockStore.instance.isLocked(widget.chat.id))
              ListTile(
                leading: Icon(Icons.fingerprint,
                    color: ChatLockStore.instance.biometricsFor(widget.chat.id)
                        ? KiteColors.accent
                        : KiteColors.muted),
                title: Text(
                    ChatLockStore.instance.biometricsFor(widget.chat.id)
                        ? 'Biométrie pour cette discussion : activée'
                        : 'Biométrie pour cette discussion',
                    style: const TextStyle(fontSize: 14.5)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  final on =
                      !ChatLockStore.instance.biometricsFor(widget.chat.id);
                  setState(() => ChatLockStore.instance
                      .setBiometricsFor(widget.chat.id, on));
                  _toast(on
                      ? 'Biométrie activée pour cette discussion — code PIN en secours'
                      : 'Biométrie désactivée pour cette discussion — code PIN uniquement');
                },
              ),
            ListTile(
              leading: Icon(Icons.timer_outlined,
                  color: widget.chat.disappearing > 0
                      ? KiteColors.accent
                      : KiteColors.muted),
              title: Text(
                widget.chat.disappearing > 0
                    ? 'Messages éphémères : ${_disappearingLabel(widget.chat.disappearing)}'
                    : 'Messages éphémères',
                style: const TextStyle(fontSize: 14.5),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showDisappearingPicker(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.chevron_right, color: KiteColors.muted),
              title:
                  const Text('Notifications', style: TextStyle(fontSize: 14.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showNotifSettings();
              },
            ),
          ],
        ),
      ),
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

  static String _disappearingLabel(int ms) {
    switch (ms) {
      case _dm24h:
        return '24 h';
      case _dm7d:
        return '7 jours';
      case _dm90d:
        return '90 jours';
      default:
        return 'désactivés';
    }
  }

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
                    () => _mockDocument(sheetCtx)),
                _attachItem(sheetCtx, Icons.photo_camera_outlined, 'Caméra',
                    () => _mockCamera(sheetCtx)),
                _attachItem(sheetCtx, Icons.photo_library_outlined, 'Galerie',
                    () => _mockGallery(sheetCtx)),
                _attachItem(sheetCtx, Icons.mic_none, 'Audio',
                    () => _mockAudio(sheetCtx)),
                _attachItem(sheetCtx, Icons.location_on_outlined,
                    'Localisation', () => _mockLocation(sheetCtx)),
                _attachItem(sheetCtx, Icons.person_outline, 'Contact',
                    () => _mockContact(sheetCtx)),
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

  // ---------- Workflows simulés de pièces jointes ----------

  Future<void> _sendMedia(String type, String text,
      [Map<String, dynamic>? media]) async {
    try {
      await widget.api
          .sendMessage(widget.chat.id, type: type, text: text, media: media);
    } catch (e) {
      _toast('Envoi impossible : $e');
    }
  }

  Future<void> _mockDocument(BuildContext ctx) async {
    final names = [
      'projet-final.pdf',
      'specs.docx',
      'budget.xlsx',
      'presentation.pptx',
      'archive.zip'
    ];
    final name = names[DateTime.now().millisecond % names.length];
    final ext = name.split('.').last.toUpperCase();
    await _sendMedia(
        'document', name, {'ext': ext, 'size': '7,8 Mo', 'pages': 24});
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
    await _sendMedia(
        'location', '', {'name': 'Position actuelle', 'live': false});
    _toast('Localisation envoyée 📍');
  }

  Future<void> _mockContact(BuildContext ctx) async {
    await _sendMedia(
        'contact', '', {'name': 'Lucas Martin', 'phone': '+33 6 12 34 56 78'});
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

/// Lecteur vocal : lecture réelle du fichier (.m4a via just_audio) quand un
/// chemin existe (enregistrement réel), sinon timeline simulée (vocals des
/// données de seed). Position exposée pour la barre de progression.
class _VoicePlayer {
  final ValueNotifier<double> progress = ValueNotifier(0);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  Timer? _t;
  int _total = 0;
  int _elapsed = 0;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  String? _loadedPath;

  bool get isPlaying => playing.value;

  void play({required int durationSec, String? path}) {
    _total = durationSec;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      _playFile(path);
      return;
    }
    // Fallback : timeline simulée (seed / vocal sans fichier).
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

  Future<void> _playFile(String path) async {
    try {
      if (_loadedPath != path) {
        await _audio.setFilePath(path);
        _loadedPath = path;
      }
      _posSub?.cancel();
      _posSub = _audio.positionStream.listen((p) {
        final d = _audio.duration;
        if (d != null && d.inMilliseconds > 0) {
          progress.value = p.inMilliseconds / d.inMilliseconds;
        }
      });
      _audio.playerStateStream.listen((s) {
        playing.value = s.playing;
        if (s.processingState == ProcessingState.completed) {
          playing.value = false;
          progress.value = 0;
          _audio.seek(Duration.zero);
          _audio.pause();
        }
      });
      await _audio.play();
    } catch (_) {
      // Fichier illisible/effacé : repli timeline.
      playing.value = false;
      play(durationSec: _total);
    }
  }

  /// Reprend la lecture là où elle en est (après pause/scrub) : fichier
  /// réel → just_audio joue depuis la position seekée ; repli timeline
  /// simulée uniquement si aucun fichier lisible.
  Future<void> resume() async {
    if (_loadedPath != null) {
      await _audio.play();
      return;
    }
    playing.value = true;
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
    if (_loadedPath != null) {
      _audio.pause();
    } else {
      playing.value = false;
    }
  }

  Future<void> setSpeed(double s) => _audio.setSpeed(s);

  /// Positionne la lecture à [fraction] (0..1) de la durée totale —
  /// scrubbing sur la waveform (fichier réel) ou timeline simulée.
  Future<void> seekTo(double fraction) async {
    final f = fraction.clamp(0.0, 1.0);
    if (_loadedPath != null) {
      final d = _audio.duration;
      if (d != null) {
        await _audio.seek(d * f);
      }
    } else {
      _elapsed = (f * _total * 5).round();
      progress.value = f;
    }
  }

  /// Stoppe tout (utilisé à la fermeture de la pré-écoute).
  Future<void> hardStop() async {
    _t?.cancel();
    _posSub?.cancel();
    try {
      await _audio.stop();
    } catch (_) {}
    playing.value = false;
  }

  void dispose() {
    _t?.cancel();
    _posSub?.cancel();
    _audio.dispose();
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
    // Pressage = ressort (scale-down, retour calme) — la même physique que
    // le reste du design system.
    return SpringScale(
      onTap: onTap,
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

class _MiniAvatar extends StatelessWidget {
  const _MiniAvatar(
      {required this.name, required this.group, this.large = false});

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
        style:
            TextStyle(fontWeight: FontWeight.w600, fontSize: large ? 22 : 13),
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
              _MiniAvatar(name: name, group: false),
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

// ---------- Tactile & motion (warm-organic) ----------

/// Swipe horizontal vers la droite sur une bulle → répondre.
/// Résistance rubber-band au-delà du seuil, haptique au franchissement,
/// retour élastique au relâchement.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 56;

  // Retour élastique piloté par ressort (durée = settle de la simulation).
  late final AnimationController _snap = AnimationController(vsync: this);
  double _drag = 0;
  bool _fired = false;

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    setState(() {
      _drag = (_drag + d.delta.dx).clamp(0.0, _threshold + 28);
      // Rubber-band : résistance progressive au-delà du seuil.
      if (_drag > _threshold) {
        _drag = _threshold + (_drag - _threshold) * 0.35;
      }
      if (_drag >= _threshold && !_fired) {
        _fired = true;
        KiteHaptics.threshold();
      } else if (_drag < _threshold) {
        _fired = false;
      }
    });
  }

  void _onEnd(DragEndDetails d) {
    if (_fired) {
      widget.onReply();
      KiteHaptics.tap();
    }
    _fired = false;
    final from = _drag;
    void snapTick() {
      if (!mounted) {
        _snap.removeListener(snapTick);
        return;
      }
      // Simulation physique : le ressort relâché à [from] redescend vers
      // 0 ; on n'écrase pas la vitesse interne du contrôleur.
      setState(() {
        _drag = from * (1 - _snap.value);
      });
    }

    // Exactement un listener par retour élastique, retiré à la fin —
    // l'accumulation ferait courir N closures par frame après N swipes.
    _snap.addListener(snapTick);
    animateWithSpring(
      _snap,
      from: 0,
      to: 1,
      spring: kKiteSpringSoft,
    ).whenComplete(() {
      _snap.removeListener(snapTick);
      if (mounted) {
        setState(() => _drag = 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Opacity(
          opacity: (_drag / _threshold).clamp(0.0, 1.0),
          child:  Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Icon(Icons.reply, size: 20, color: KiteColors.muted),
          ),
        ),
        Transform.translate(
          offset: Offset(_drag, 0),
          child: GestureDetector(
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: _onUpdate,
            onHorizontalDragEnd: _onEnd,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// Barre de réactions flottante : les emojis apparaissent avec un rebond
/// de ressort (cascade douce).
class SpringReactionBar extends StatelessWidget {
  const SpringReactionBar({super.key, required this.onPick});

  final void Function(String emoji) onPick;

  static const _emojis = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < _emojis.length; i++)
          _SpringEmoji(
            emoji: _emojis[i],
            delay: i * 40,
            onTap: () => onPick(_emojis[i]),
          ),
      ],
    );
  }
}

class _SpringEmoji extends StatefulWidget {
  const _SpringEmoji({
    required this.emoji,
    required this.delay,
    required this.onTap,
  });

  final String emoji;
  final int delay;
  final VoidCallback onTap;

  @override
  State<_SpringEmoji> createState() => _SpringEmojiState();
}

class _SpringEmojiState extends State<_SpringEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late final Animation<double> _scale = Tween<double>(
    begin: 0.0,
    end: 1.0,
  ).animate(_c);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) animateWithSpring(_c);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        KiteHaptics.reactTick();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: ScaleTransition(
          scale: _scale,
          child:
              Text(widget.emoji, style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }
}

/// Waveform organique : barres arrondies à hauteur d'amplitude, portion
/// jouée en pleine couleur, à venir en atténué.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.playedColor,
    required this.pendingColor,
  });

  final List<double> bars;
  final double progress;
  final Color playedColor;
  final Color pendingColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const gap = 2.0;
    final barW = size.width / bars.length - gap;
    final mid = size.height / 2;
    final playedUpTo = size.width * progress.clamp(0.0, 1.0);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final x = i * (barW + gap) + barW / 2;
      final h = (6.0 + bars[i] * (size.height - 6))
          .clamp(4.0, size.height)
          .toDouble();
      paint.color =
          x <= playedUpTo ? playedColor : pendingColor;
      paint.strokeWidth = barW.clamp(1.5, 4.0);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.playedColor != playedColor;
}

/// Pré-écoute d'un vocal avant envoi : lecture/pause, scrub sur la waveform
/// (amplitudes captées pendant l'enregistrement), vitesse, abandon.
class _VoiceReviewSheet extends StatefulWidget {
  const _VoiceReviewSheet({
    required this.player,
    required this.bars,
    required this.durationSec,
  });

  final _VoicePlayer player;
  final List<double> bars;
  final int durationSec;

  @override
  State<_VoiceReviewSheet> createState() => _VoiceReviewSheetState();
}

class _VoiceReviewSheetState extends State<_VoiceReviewSheet> {
  double _speed = 1.0;
  double _scrub = 0;

  @override
  void initState() {
    super.initState();
    widget.player.progress.addListener(_onProgress);
  }

  void _onProgress() {
    if (mounted) setState(() => _scrub = widget.player.progress.value);
  }

  @override
  void dispose() {
    widget.player.progress.removeListener(_onProgress);
    super.dispose();
  }

  String get _time {
    final total = widget.durationSec;
    final pos = (total * _scrub).round();
    final p = '${(pos ~/ 60).toString().padLeft(2, '0')}:${(pos % 60).toString().padLeft(2, '0')}';
    final t = '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
    return '$p / $t';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 18, color: KiteColors.accent),
              const SizedBox(width: 8),
              const Text(
                'Écouter avant d’envoyer',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(_time,
                  style:  TextStyle(
                      color: KiteColors.muted,
                      fontSize: 12,
                      fontFamilyFallback: const ['monospace'])),
            ],
          ),
          const SizedBox(height: 14),
          // Waveform scrubbable (les vraies amplitudes captées).
          GestureDetector(
            onHorizontalDragUpdate: (d) async {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final f = (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
              await player.seekTo(f);
            },
            onHorizontalDragEnd: (_) {
              if (!player.playing.value) {
                player.resume();
              }
            },
            child: SizedBox(
              height: 44,
              child: CustomPaint(
                painter: _WaveformPainter(
                  bars: widget.bars,
                  progress: _scrub,
                  playedColor: KiteColors.accent,
                  pendingColor: KiteColors.accent.withValues(alpha: 0.32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Pause / reprise.
              ValueListenableBuilder<bool>(
                valueListenable: player.playing,
                builder: (_, playing, __) => _RoundBtn(
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  tooltip: playing ? 'Pause' : 'Reprendre',
                  accent: true,
                  onTap: () {
                    if (playing) {
                      player.pause();
                    } else {
                      player.resume();
                    }
                  },
                ),
              ),
              const SizedBox(width: 18),
              // Vitesse cyclée 1x → 1,5x → 2x.
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () async {
                  KiteHaptics.tap();
                  final next = _speed == 1.0 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
                  setState(() => _speed = next);
                  await player.setSpeed(next);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: KiteColors.surface2,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: KiteColors.border),
                  ),
                  child: Text(
                    '${_speed}x',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KiteColors.ephemeral,
                    side: BorderSide(
                        color: KiteColors.ephemeral.withValues(alpha: 0.5)),
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Abandonner'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: KiteColors.accent,
                    foregroundColor: KiteColors.accentInk,
                  ),
                  onPressed: () {
                    KiteHaptics.send();
                    Navigator.pop(context, true);
                  },
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Envoyer'),
                ),
              ),
            ],
          ),
        ],
      ),
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
