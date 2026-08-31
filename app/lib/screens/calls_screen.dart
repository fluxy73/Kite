import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/// Onglet Appels : favoris, récents, lien d'appel et appel en cours (timer réel).
class CallsScreen extends StatelessWidget {
  const CallsScreen({
    super.key,
    required this.api,
    required this.shell,
    required this.onRefresh,
  });

  final KiteApi api;
  final AppShell shell;
  final Future<void> Function() onRefresh;

  static const _favorites = ['u-lucas', 'u-emma', 'u-thomas'];

  @override
  Widget build(BuildContext context) {
    final favorites = shell.users
        .where((u) => _favorites.contains(u.id))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const _SectionTitle('Favoris'),
            _favoritesRow(context, favorites),
            const _SectionTitle('Récents'),
            Expanded(child: _recents(context)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: KiteColors.accent,
        foregroundColor: KiteColors.accentInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => newCall(context),
        child: const Icon(Icons.add_ic_call_outlined),
      ),
    );
  }

  Widget _favoritesRow(BuildContext context, List<User> favorites) {
    if (favorites.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('Aucun favori pour l’instant', style: TextStyle(color: KiteColors.muted)),
      );
    }
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: favorites.length,
        itemBuilder: (context, i) {
          final u = favorites[i];
          return _FavoriteAvatar(
            user: u,
            onAudio: () =>
                _contactCall(context, u.id, name: u.name), // audio
            onVideo: () =>
                _contactCall(context, u.id, name: u.name, video: true),
          );
        },
      ),
    );
  }

  Widget _recents(BuildContext context) {
    if (shell.calls.isEmpty) {
      return const _EmptyCalls();
    }
    final recents = [...shell.calls]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: recents.length,
        itemBuilder: (context, i) => _CallRow(
          call: recents[i],
          onTap: () => _contactCall(context, recents[i].userId,
              name: recents[i].name, group: recents[i].group, video: recents[i].isVideo),
        ),
      ),
    );
  }

  void newCall(BuildContext context) {
    final contacts = shell.users.where((u) => u.id != api.meId).toList();
    final groups = shell.chats.where((c) => c.isGroup).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Nouvel appel', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const ListTile(
              leading: Icon(Icons.link, color: KiteColors.accent),
              title: Text('Créer un lien d’appel', style: TextStyle(color: KiteColors.fg)),
            ),
            for (final u in contacts)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: KiteColors.surface2,
                  child: Text(_initials(u.name), style: const TextStyle(fontSize: 12)),
                ),
                title: Text(u.name, style: const TextStyle(color: KiteColors.fg)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.call_outlined, color: KiteColors.tint2),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _contactCall(context, u.id, name: u.name);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.videocam_outlined, color: KiteColors.tint1),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _contactCall(context, u.id, name: u.name, video: true);
                      },
                    ),
                  ],
                ),
              ),
            if (groups.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text('Appel de groupe', style: TextStyle(color: KiteColors.muted, fontSize: 13)),
              ),
              for (final g in groups.take(4))
                ListTile(
                  leading: const Icon(Icons.groups_outlined, color: KiteColors.accent),
                  title: Text(g.name, style: const TextStyle(color: KiteColors.fg)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _contactCall(context, g.id, name: g.name, group: true);
                  },
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Démarre un appel (mock) : skippe le log pour un appel réel et ouvre l'écran d'appel.
  void _contactCall(BuildContext context, String id,
      {required String name, bool group = false, bool video = false}) {
    // Log de l'appel dans la conversation correspondante (branché serveur).
    final chat = shell.chats.where((c) => c.id == id || c.name == name).firstOrNull;
    if (chat != null) {
      api.logCall(chat.id, kind: video ? 'video' : 'audio')
          .catchError((_) => null);
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InCallScreen(name: name, group: group, video: video),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.split(' ').where((w) => w.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((w) => w[0].toUpperCase()).join();
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Appels',
              style: TextStyle(
                fontFamilyFallback: kDisplayFont,
                fontSize: 26,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Créer un lien d’appel',
            onPressed: () => _linkSheet(context),
          ),
        ],
      ),
    );
  }

  void _linkSheet(BuildContext context) {
    final url = 'https://kite.chat/call/${DateTime.now().millisecondsSinceEpoch % 100000}';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Lien d’appel', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              SelectableText(url, style: const TextStyle(color: KiteColors.accent)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: KiteColors.accent),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Lien copié dans le presse-papiers')),
                        );
                      },
                      icon: const Icon(Icons.copy, color: KiteColors.accentInk),
                      label: const Text('Copier', style: TextStyle(color: KiteColors.accentInk)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(title,
          style: const TextStyle(color: KiteColors.muted, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}

class _FavoriteAvatar extends StatelessWidget {
  const _FavoriteAvatar({required this.user, required this.onAudio, required this.onVideo});
  final User user;
  final VoidCallback onAudio;
  final VoidCallback onVideo;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          GestureDetector(
            onDoubleTap: onVideo,
            onLongPress: onVideo,
            child: _Avatar(name: user.name, size: 56),
          ),
          Text(user.name.split(' ').first,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: KiteColors.fg)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(onTap: onAudio, child: const Icon(Icons.call, size: 16, color: KiteColors.tint2)),
              const SizedBox(width: 10),
              InkWell(onTap: onVideo, child: const Icon(Icons.videocam, size: 16, color: KiteColors.tint1)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CallRow extends StatelessWidget {
  const _CallRow({required this.call, required this.onTap});
  final CallLog call;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = call.direction == 'missed' ? KiteColors.danger : KiteColors.fg;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _Avatar(name: call.name),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(call.name,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: KiteColors.fg)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(_directionIcon(call.direction), size: 14, color: color),
                      const SizedBox(width: 4),
                      Text(_directionLabel(call),
                          style: TextStyle(color: color, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
            Text(_timeOf(call.createdAt), style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  static IconData _directionIcon(String d) {
    switch (d) {
      case 'outgoing':
        return Icons.arrow_upward;
      case 'missed':
        return Icons.arrow_downward;
      default:
        return Icons.arrow_downward;
    }
  }

  static String _directionLabel(CallLog c) {
    final d = c.direction == 'missed' ? 'Manqué' : (c.direction == 'outgoing' ? 'Sortant' : 'Entrant');
    return '${c.isVideo ? 'Vidéo' : 'Audio'} · $d';
  }

  static String _timeOf(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.size = 44});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final parts = name.split(' ').where((w) => w.isNotEmpty).toList();
    final initials = parts.isEmpty ? '?' : parts.take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(size / 2),
        border: Border.all(color: KiteColors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: size * 0.32),
      ),
    );
  }
}

class _EmptyCalls extends StatelessWidget {
  const _EmptyCalls();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.call_outlined, size: 44, color: KiteColors.muted),
          SizedBox(height: 10),
          Text('Aucun appel', style: TextStyle(color: KiteColors.muted)),
        ],
      ),
    );
  }
}

// ---------- Écran d'appel (timer réel) ----------

class InCallScreen extends StatefulWidget {
  const InCallScreen({
    super.key,
    required this.name,
    this.group = false,
    this.video = false,
  });

  final String name;
  final bool group;
  final bool video;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  late final Timer _ticker;
  final Stopwatch _sw = Stopwatch()..start();
  bool _muted = false;
  bool _speaker = true;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed = _sw.elapsed.inSeconds);
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    _sw.stop();
    super.dispose();
  }

  String get _timerText {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KiteColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            _Avatar(name: widget.name),
            const SizedBox(height: 20),
            Text(widget.name,
                style: const TextStyle(fontSize: 24, fontFamilyFallback: kDisplayFont, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            if (widget.group)
              const Text('Appel de groupe', style: TextStyle(color: KiteColors.muted, fontSize: 14))
            else
              Text(_timerText, style: const TextStyle(color: KiteColors.muted, fontSize: 16)),
            const Spacer(),
            _controls(),
            const SizedBox(height: 18),
            _HangupButton(
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 24),
            const Text('🔒 Chiffré de bout en bout',
                style: TextStyle(color: KiteColors.muted, fontSize: 11)),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final items = [
      _Control(icon: _muted ? Icons.mic_off : Icons.mic, label: _muted ? 'Activer' : 'Muet', active: _muted, onTap: () => setState(() => _muted = !_muted)),
      _Control(icon: Icons.volume_up, label: _speaker ? 'Haut-parleur' : 'Écouteur', active: _speaker, onTap: () => setState(() => _speaker = !_speaker)),
      _Control(icon: Icons.videocam, label: 'Vidéo', active: widget.video, onTap: () {}),
      _Control(icon: Icons.person_add_alt, label: 'Ajouter', active: false, onTap: () {}),
      _Control(icon: Icons.more_horiz, label: 'Plus', active: false, onTap: () {}),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: items,
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: active ? KiteColors.accent : KiteColors.surface2,
              child: Icon(icon, size: 20, color: active ? KiteColors.accentInk : KiteColors.fg),
            ),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: KiteColors.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _HangupButton extends StatelessWidget {
  const _HangupButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(color: KiteColors.danger, shape: BoxShape.circle),
        child: const Icon(Icons.call_end, size: 26, color: Colors.white),
      ),
    );
  }
}