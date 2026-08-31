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
            _Header(
              onDemoCall: () => _simulateIncoming(context),
              onSchedule: () => _planCall(context),
            ),
            const _SectionTitle('Favoris'),
            _favoritesRow(context, favorites),
            const _SectionTitle('Planifiés'),
            _ScheduledSection(
              calls: shell.scheduledCalls,
              onToggleReminder: (sc) => _toggleReminder(context, sc),
              onDelete: (sc) => _deleteScheduled(context, sc),
              onPlan: () => _planCall(context),
            ),
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
            onAudio: () => _contactCall(context, u.id, name: u.name),
            onVideo: () => _contactCall(context, u.id, name: u.name, video: true),
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

  /// Simule un appel entrant réel : Lucas (u-lucas) initie un appel dans
  /// c-lucas -> le serveur broadcast l'event "call" -> l'écran qui sonne s'affiche.
  void _simulateIncoming(BuildContext context) {
    api.initiateCall('c-lucas', kind: 'video').catchError((_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Serveur injoignable : lancez le serveur Go')),
        );
      }
      return <String, dynamic>{};
    });
  }

  /// Ouvre le formulaire de planification (titre, date/heure, participants, rappel).
  void _planCall(BuildContext context) {
    final titleCtrl = TextEditingController();
    final contacts = shell.users.where((u) => u.id != api.meId).toList();
    bool video = false;
    bool reminder = false;
    final selected = <String>{};
    DateTime picked = DateTime.now().add(const Duration(hours: 1));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            void submit() async {
              final title = titleCtrl.text.trim();
              if (title.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Le titre est requis')));
                return;
              }
              Navigator.pop(sheetCtx);
              try {
                await api.createScheduledCall(
                  title: title,
                  scheduledAt: picked.millisecondsSinceEpoch,
                  kind: video ? 'video' : 'audio',
                  memberIds: selected.toList(),
                  chatId: '',
                  reminder: reminder,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Appel planifié ✅')));
                }
                await onRefresh();
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Serveur injoignable')));
                }
              }
            }
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Planifier un appel', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleCtrl,
                      style: const TextStyle(color: KiteColors.fg),
                      decoration: const InputDecoration(
                        labelText: 'Titre',
                        hintText: "Ex. Point d'équipe",
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final d = await showDatePicker(
                                context: sheetCtx,
                                initialDate: picked,
                                firstDate: DateTime.now(),
                                lastDate: DateTime.now().add(const Duration(days: 365)),
                              );
                              if (d != null) {
                                setSheet(() => picked = DateTime(d.year, d.month, d.day, picked.hour, picked.minute));
                              }
                            },
                            icon: const Icon(Icons.calendar_today, size: 16),
                            label: const Text('Date'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final t = await showTimePicker(context: sheetCtx, initialTime: TimeOfDay.fromDateTime(picked));
                              if (t != null) {
                                setSheet(() => picked = DateTime(picked.year, picked.month, picked.day, t.hour, t.minute));
                              }
                            },
                            icon: const Icon(Icons.schedule, size: 16),
                            label: const Text('Heure'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(_ScheduledCard.fmt(dt: picked), style: const TextStyle(color: KiteColors.accent, fontSize: 13)),
                    const SizedBox(height: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, icon: Icon(Icons.call), label: Text('Audio')),
                        ButtonSegment(value: true, icon: Icon(Icons.videocam), label: Text('Vidéo')),
                      ],
                      selected: {video},
                      onSelectionChanged: (sel) => setSheet(() => video = sel.first),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: reminder,
                      onChanged: (v) => setSheet(() => reminder = v),
                      title: const Text('Rappel', style: TextStyle(color: KiteColors.fg)),
                      subtitle: const Text("Notifier avant l'appel", style: TextStyle(color: KiteColors.muted, fontSize: 12)),
                      secondary: const Icon(Icons.notifications_outlined),
                    ),
                    const SizedBox(height: 4),
                    const Text('Participants', style: TextStyle(color: KiteColors.muted, fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 4),
                    ...contacts.map((u) => CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: selected.contains(u.id),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(u.id);
                            } else {
                              selected.remove(u.id);
                            }
                          }),
                          title: Text(u.name, style: const TextStyle(color: KiteColors.fg)),
                        )),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: KiteColors.accent),
                        onPressed: submit,
                        child: const Text('Planifier', style: TextStyle(color: KiteColors.accentInk)),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Bascule le rappel d'un appel planifié puis re-synchronise le shell.
  Future<void> _toggleReminder(BuildContext context, ScheduledCall sc) async {
    try {
      await api.toggleScheduledReminder(sc.id);
      await onRefresh();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Serveur injoignable')));
      }
    }
  }

  /// Supprime un appel planifié (après confirmation) puis re-synchronise le shell.
  Future<void> _deleteScheduled(BuildContext context, ScheduledCall sc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text("Supprimer l'appel ?"),
        content: Text('« ${sc.title} » sera supprimé.', style: const TextStyle(color: KiteColors.fg)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Supprimer', style: TextStyle(color: KiteColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deleteScheduledCall(sc.id);
      await onRefresh();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Serveur injoignable')));
      }
    }
  }

  /// Démarre un appel (mock) et journalise l'appel dans la conversation (branché serveur).
  void _contactCall(BuildContext context, String id,
      {required String name, bool group = false, bool video = false}) {
    final chat = shell.chats.where((c) => c.id == id || c.name == name).firstOrNull;
    if (chat != null) {
      api.logCall(chat.id, kind: video ? 'video' : 'audio').catchError((_) => null);
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          name: name,
          group: group,
          video: video,
          memberNames: group ? _groupMembers(name) : [name],
        ),
      ),
    );
  }

  /// Participants mockés d'un appel de groupe (seed serveur + compléments).
  static List<String> _groupMembers(String groupName) {
    final known = <String, List<String>>{
      'Projet Nova': ['Lucas Martin', 'Emma Bernard', 'Thomas Petit', 'Sarah Kacem'],
      'Impression 3D': ['Thomas Petit', 'Sarah Kacem'],
      'Électronique': ['Lucas Martin', 'Thomas Petit'],
      'Atelier design': ['Emma Bernard', 'Sarah Kacem'],
    };
    final base = known[groupName] ?? <String>['Lucas Martin', 'Emma Bernard'];
    final extra = <String>['Thomas Petit', 'Sarah Kacem'];
    final out = [...base];
    for (final e in extra) {
      if (out.length >= 4) break;
      if (!out.contains(e)) out.add(e);
    }
    return out;
  }

  static String _initials(String name) {
    final parts = name.split(' ').where((w) => w.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((w) => w[0].toUpperCase()).join();
  }
}

class _Header extends StatelessWidget {
  const _Header({this.onDemoCall, this.onSchedule});

  /// Déclenche un appel entrant simulé (démo du flux temps réel).
  final VoidCallback? onDemoCall;

  /// Ouvre le formulaire de planification d'un appel.
  final VoidCallback? onSchedule;

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
          IconButton(
            icon: const Icon(Icons.event_outlined),
            tooltip: 'Planifier un appel',
            onPressed: onSchedule,
          ),
          IconButton(
            icon: const Icon(Icons.phone_in_talk_outlined),
            tooltip: 'Simuler un appel entrant (démo)',
            onPressed: onDemoCall,
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
              SizedBox(
                width: double.infinity,
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

// ---------- Appels planifiés ----------

class _ScheduledSection extends StatelessWidget {
  const _ScheduledSection({
    required this.calls,
    required this.onToggleReminder,
    required this.onDelete,
    required this.onPlan,
  });

  final List<ScheduledCall> calls;
  final void Function(ScheduledCall) onToggleReminder;
  final void Function(ScheduledCall) onDelete;
  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    if (calls.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Text('Aucun appel planifié', style: TextStyle(color: KiteColors.muted)),
            const Spacer(),
            TextButton.icon(onPressed: onPlan, icon: const Icon(Icons.event, size: 16), label: const Text('Planifier')),
          ],
        ),
      );
    }
    final sorted = [...calls]..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return SizedBox(
      height: 132,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final sc in sorted)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _ScheduledCard(
                call: sc,
                onToggleReminder: () => onToggleReminder(sc),
                onDelete: () => onDelete(sc),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScheduledCard extends StatelessWidget {
  const _ScheduledCard({required this.call, required this.onToggleReminder, required this.onDelete});

  final ScheduledCall call;
  final VoidCallback onToggleReminder;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(call.scheduledAt);
    final isPast = dt.isBefore(DateTime.now());
    return Container(
      width: 178,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isPast ? KiteColors.border : KiteColors.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(call.kind == 'video' ? Icons.videocam : Icons.call, size: 16, color: KiteColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(call.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: KiteColors.fg)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(fmt(dt: dt), style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(call.memberIds.isEmpty ? 'Juste moi' : '${call.memberIds.length} participant(s)',
              style: const TextStyle(color: KiteColors.muted, fontSize: 11)),
          const Spacer(),
          Row(
            children: [
              InkWell(
                onTap: onToggleReminder,
                child: Row(
                  children: [
                    Icon(call.reminder ? Icons.notifications_active : Icons.notifications_none,
                        size: 16, color: call.reminder ? KiteColors.tint2 : KiteColors.muted),
                    const SizedBox(width: 4),
                    const Text('Rappel', style: TextStyle(color: KiteColors.muted, fontSize: 11)),
                  ],
                ),
              ),
              const Spacer(),
              InkWell(onTap: onDelete, child: const Icon(Icons.delete_outline, size: 18, color: KiteColors.danger)),
            ],
          ),
        ],
      ),
    );
  }

  static String fmt({required DateTime dt}) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d $h:$min';
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

// ==================== Écran d'appel (grille de groupe + partage + réactions) ====================

/// Réaction temporaire affichée en surimpression pendant l'appel.
class _Reaction {
  _Reaction(this.emoji, this.id);
  final String emoji;
  final int id;
}

class InCallScreen extends StatefulWidget {
  const InCallScreen({
    super.key,
    required this.name,
    this.group = false,
    this.video = false,
    this.memberNames = const [],
  });

  final String name;
  final bool group;
  final bool video;

  /// Participants (hors moi) pour la grille d'appel de groupe.
  final List<String> memberNames;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  late final Timer _ticker;
  final Stopwatch _sw = Stopwatch()..start();
  bool _muted = false;
  bool _speaker = true;
  bool _videoOn = true;
  bool _sharing = false;
  String? _sharerName;
  int _elapsed = 0;
  int _reactionSeq = 0;
  final List<_Reaction> _reactions = [];

  static const _emojis = ['❤️', '😂', '😮', '😢', '👍', '👏'];

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

  /// Participants affichés : les membres + moi, dans un ordre stable.
  List<String> get _participants {
    final names = <String>[...widget.memberNames];
    if (names.length < 3) {
      for (final e in const ['Lucas Martin', 'Emma Bernard', 'Thomas Petit']) {
        if (names.length >= 3) break;
        if (!names.contains(e)) names.add(e);
      }
    }
    if (!names.contains('Moi')) names.add('Moi');
    return names;
  }

  void _toggleShare() {
    setState(() {
      _sharing = !_sharing;
      _sharerName = _sharing ? 'Moi' : null;
    });
  }

  void _fireReaction() {
    final emoji = _emojis[_reactionSeq % _emojis.length];
    setState(() => _reactions.add(_Reaction(emoji, _reactionSeq++)));
    Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        setState(() {
          _reactions.removeWhere((r) => r.id == _reactionSeq - 1);
        });
      }
    });
  }

  void _showParticipants() {
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
              child: Text('Participants', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            for (final name in _participants)
              ListTile(
                dense: true,
                leading: _Avatar(name: name, size: 36),
                title: Row(
                  children: [
                    Text(name, style: const TextStyle(color: KiteColors.fg)),
                    if (name == 'Moi') ...[
                      const SizedBox(width: 6),
                      const Text('(vous)', style: TextStyle(color: KiteColors.muted, fontSize: 12)),
                    ],
                  ],
                ),
                subtitle: name == 'Lucas Martin'
                    ? const Row(children: [
                        Icon(Icons.mic_off, size: 13, color: KiteColors.danger),
                        SizedBox(width: 4),
                        Text('En sourdine', style: TextStyle(color: KiteColors.muted, fontSize: 12)),
                      ])
                    : null,
                trailing: PopupMenuButton<String>(
                  color: KiteColors.surface2,
                  icon: const Icon(Icons.more_vert, color: KiteColors.muted),
                  onSelected: (v) {
                    if (v == 'share') {
                      Navigator.pop(sheetCtx);
                      setState(() {
                        _sharing = true;
                        _sharerName = name;
                      });
                    }
                  },
                  itemBuilder: (_) => [
                    if (name != 'Moi')
                      const PopupMenuItem(value: 'share', child: Text('Lui donner l’écran', style: TextStyle(color: KiteColors.fg))),
                    const PopupMenuItem(value: 'msg', child: Text('Envoyer un message', style: TextStyle(color: KiteColors.fg))),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final participants = _participants;
    return Scaffold(
      backgroundColor: KiteColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                Expanded(
                  child: _sharing
                      ? _sharingLayout(participants)
                      : _gridLayout(participants),
                ),
                _controls(),
                const SizedBox(height: 14),
                _HangupButton(onTap: () => Navigator.of(context).pop()),
                const SizedBox(height: 16),
                const Text('🔒 Chiffré de bout en bout',
                    style: TextStyle(color: KiteColors.muted, fontSize: 11)),
                const SizedBox(height: 10),
              ],
            ),
          ),
          // Réactions en surimpression
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final r in _reactions)
                      _FloatingReaction(key: ValueKey(r.id), emoji: r.emoji),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              children: [
                Text(widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontFamilyFallback: kDisplayFont, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(_timerText, style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  /// Grille responsive : colonnes selon la largeur d'écran et le nombre de participants.
  Widget _gridLayout(List<String> participants) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 720
            ? 3
            : (participants.length <= 2 ? 2 : (participants.length <= 4 ? 2 : 3));
        final cellAspect = width >= 720 ? 16 / 9 : 3 / 4;
        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: cellAspect,
          ),
          itemCount: participants.length,
          itemBuilder: (context, i) => _ParticipantTile(
            name: participants[i],
            isMe: participants[i] == 'Moi',
            muted: _muted && participants[i] == 'Moi',
            videoOn: _videoOn && participants[i] == 'Moi',
            speaking: i == _elapsed % participants.length,
          ),
        );
      },
    );
  }

  /// Mode partage d'écran : l'écran partagé au centre, les autres en bandeau.
  Widget _sharingLayout(List<String> participants) {
    final sharer = _sharerName ?? 'Moi';
    final others = participants.where((p) => p != sharer).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.screen_share, size: 15, color: KiteColors.tint2),
              const SizedBox(width: 6),
              Flexible(
                child: Text('$sharer partage son écran',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            decoration: BoxDecoration(
              color: KiteColors.surface2,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: KiteColors.tint2.withValues(alpha: 0.5)),
            ),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monitor, size: 42, color: KiteColors.muted),
                  SizedBox(height: 8),
                  Text('Contenu de l’écran partagé',
                      style: TextStyle(color: KiteColors.muted, fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          height: 108,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final name in others)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 132,
                    child: _ParticipantTile(
                      name: name,
                      isMe: name == 'Moi',
                      muted: _muted && name == 'Moi',
                      videoOn: _videoOn && name == 'Moi',
                      speaking: false,
                      compact: true,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls() {
    final items = [
      _Control(
        icon: _muted ? Icons.mic_off : Icons.mic,
        label: _muted ? 'Activer' : 'Muet',
        active: _muted,
        onTap: () => setState(() => _muted = !_muted),
      ),
      _Control(
        icon: _speaker ? Icons.volume_up : Icons.volume_off,
        label: 'Haut-parleur',
        active: _speaker,
        onTap: () => setState(() => _speaker = !_speaker),
      ),
      _Control(
        icon: _videoOn ? Icons.videocam : Icons.videocam_off,
        label: _videoOn ? 'Vidéo' : 'Caméra off',
        active: _videoOn,
        onTap: () => setState(() => _videoOn = !_videoOn),
      ),
      _Control(
        icon: _sharing ? Icons.stop_screen_share : Icons.screen_share,
        label: _sharing ? 'Arrêter' : 'Partage',
        active: _sharing,
        onTap: _toggleShare,
      ),
      _Control(
        icon: Icons.emoji_emotions_outlined,
        label: 'Réactions',
        active: false,
        onTap: _fireReaction,
      ),
      _Control(
        icon: Icons.groups_outlined,
        label: 'Participants',
        active: false,
        onTap: _showParticipants,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: items,
      ),
    );
  }
}

/// Tuile d'un participant dans la grille d'appel (flux vidéo simulé).
class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.name,
    required this.isMe,
    required this.muted,
    required this.videoOn,
    required this.speaking,
    this.compact = false,
  });

  final String name;
  final bool isMe;
  final bool muted;
  final bool videoOn;
  final bool speaking;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: KiteColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: speaking ? KiteColors.tint2 : KiteColors.border,
          width: speaking ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  KiteColors.surface3,
                  KiteColors.surface,
                  KiteColors.surface2.withValues(alpha: 0.6),
                ],
              ),
            ),
          ),
          if (videoOn || !isMe)
            Center(
              child: _Avatar(name: name, size: compact ? 40 : 56),
            )
          else
            const Center(
              child: Icon(Icons.videocam_off, size: 30, color: KiteColors.muted),
            ),
          Positioned(
            left: 8,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isMe ? '$name (vous)' : name,
                style: const TextStyle(fontSize: 11, color: KiteColors.fg),
              ),
            ),
          ),
          if (muted)
            const Positioned(
              top: 8,
              right: 8,
              child: Icon(Icons.mic_off, size: 16, color: KiteColors.danger),
            ),
          if (speaking)
            const Positioned(
              top: 8,
              right: 8,
              child: Icon(Icons.graphic_eq, size: 18, color: KiteColors.tint2),
            ),
        ],
      ),
    );
  }
}

/// Réaction qui flotte et disparaît au-dessus de l'appel.
class _FloatingReaction extends StatelessWidget {
  const _FloatingReaction({super.key, required this.emoji});
  final String emoji;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.4),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) => Opacity(
        opacity: (2.2 - scale).clamp(0.0, 1.0),
        child: Transform.scale(scale: scale, child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Text(emoji, style: const TextStyle(fontSize: 34)),
      ),
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
