import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'conversation_screen.dart';

/// Onglet Communautés : liste des communautés, détail (annonces + groupes),\n///création et rattachement de groupes — branchés sur /api/shell et /api/communities.
class CommunitiesScreen extends StatelessWidget {
  const CommunitiesScreen({
    super.key,
    required this.api,
    required this.shell,
    required this.onRefresh,
  });

  final KiteApi api;
  final AppShell shell;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'L’actualité de vos groupes au même endroit.',
                style: TextStyle(color: KiteColors.muted, fontSize: 13),
              ),
            ),
            Expanded(child: _list(context)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: KiteColors.accent,
        foregroundColor: KiteColors.accentInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => _createCommunity(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (shell.communities.isEmpty) {
      return const _Empty();
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: shell.communities.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: KiteColors.border),
        itemBuilder: (context, i) {
          final cm = shell.communities[i];
          return ListTile(
            onTap: () => _openCommunity(context, cm),
            leading: _CommunityAvatar(name: cm.name),
            title: Text(cm.name, style: const TextStyle(color: KiteColors.fg, fontWeight: FontWeight.w600)),
            subtitle: Text(
              cm.description.isNotEmpty ? cm.description : '${cm.groups.length} groupe(s)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: KiteColors.muted, fontSize: 13),
            ),
            trailing: const Icon(Icons.chevron_right, color: KiteColors.muted),
          );
        },
      ),
    );
  }

  void _openCommunity(BuildContext context, Community cm) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _CommunityDetailScreen(api: api, community: cm),
      ),
    );
  }

  /// Workflow de création : nom + description, puis rattachement de groupes.
  void _createCommunity(BuildContext context) {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final groupChats = shell.chats.where((c) => c.isGroup).toList();
    final selected = <String>{};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 20,
        ),
        child: StatefulBuilder(
          builder: (sheetCtx, setSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nouvelle communauté',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(hintText: 'Nom de la communauté'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(hintText: 'Description'),
              ),
              if (groupChats.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Groupes à rattacher', style: TextStyle(color: KiteColors.muted, fontSize: 13)),
                const SizedBox(height: 6),
                for (final g in groupChats.take(8))
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(g.id),
                    title: Text(g.name, style: const TextStyle(fontSize: 14)),
                    activeColor: KiteColors.accent,
                    onChanged: (v) => setSheet(() {
                      if (v == true) {
                        selected.add(g.id);
                      } else {
                        selected.remove(g.id);
                      }
                    }),
                  ),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: KiteColors.accent),
                  onPressed: () async {
                    if (nameCtrl.text.trim().isEmpty) return;
                    await api.createCommunity(
                      name: nameCtrl.text.trim(),
                      description: descCtrl.text.trim(),
                      groupIds: selected.toList(),
                    );
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                    await onRefresh();
                  },
                  child: const Text('Créer', style: TextStyle(color: KiteColors.accentInk)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        'Communautés',
        style: TextStyle(
          fontFamilyFallback: kDisplayFont,
          fontSize: 26,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _CommunityAvatar extends StatelessWidget {
  const _CommunityAvatar({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KiteColors.border),
      ),
      alignment: Alignment.center,
      child: Text(initials, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.grid_view_outlined, size: 44, color: KiteColors.muted),
          SizedBox(height: 10),
          Text('Aucune communauté', style: TextStyle(color: KiteColors.muted)),
        ],
      ),
    );
  }
}

// ---------- Détail d'une communauté ----------

class _CommunityDetailScreen extends StatefulWidget {
  const _CommunityDetailScreen({required this.api, required this.community});
  final KiteApi api;
  final Community community;

  @override
  State<_CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<_CommunityDetailScreen> {
  final List<Chat> _groups = <Chat>[];

  @override
  void initState() {
    super.initState();
    _groups.addAll(widget.community.groups);
  }

  void _addGroup() {
    // Pick : groupes du shell non encore rattachés à cette communauté (séquence complète).
    // On affiche une moquerie branchée : un choix de groupes + ajout.
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
              child: Text('Ajouter un groupe', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const ListTile(
              leading: Icon(Icons.group_add_outlined, color: KiteColors.accent),
              title: Text('Créer un nouveau groupe', style: TextStyle(color: KiteColors.fg)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Groupes existants', style: TextStyle(color: KiteColors.muted, fontSize: 13)),
            ),
            for (final g in <String>['Projet Nova', 'Impression 3D', 'Électronique', 'Atelier design'])
              ListTile(
                leading: const Icon(Icons.groups_outlined, color: KiteColors.accent),
                title: Text(g, style: const TextStyle(color: KiteColors.fg)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  setState(() {
                    _groups.add(Chat(
                      id: 'g-${g.toLowerCase().replaceAll(' ', '-')}',
                      type: 'group',
                      name: g,
                      memberIds: [widget.api.meId],
                      adminIds: [widget.api.meId],
                    ));
                  });
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cm = widget.community;
    return Scaffold(
      appBar: AppBar(title: Text(cm.name)),
      backgroundColor: KiteColors.bg,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(child: _CommunityAvatar(name: cm.name)),
          const SizedBox(height: 12),
          Center(
            child: Text(cm.name,
                style: const TextStyle(fontSize: 20, fontFamilyFallback: kDisplayFont, fontWeight: FontWeight.w500)),
          ),
          if (cm.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: Text(cm.description,
                    textAlign: TextAlign.center, style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
              ),
            ),
          const SizedBox(height: 24),
          const Text('Annonces', style: TextStyle(color: KiteColors.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: KiteColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: KiteColors.border),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bienvenue dans la communauté 👋', style: TextStyle(color: KiteColors.fg, fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('Les annonces seront diffusées ici.',
                    style: TextStyle(color: KiteColors.muted, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text('Groupes', style: TextStyle(color: KiteColors.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final g in _groups)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.groups_outlined, color: KiteColors.accent),
              title: Text(g.name, style: const TextStyle(color: KiteColors.fg)),
              trailing: const Icon(Icons.chevron_right, color: KiteColors.muted),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ConversationScreen(
                    api: widget.api,
                    chat: g,
                    // chargement à la demande dans l'écran de conversation
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addGroup,
            icon: const Icon(Icons.add),
            label: const Text('Ajouter un groupe'),
            style: OutlinedButton.styleFrom(
              foregroundColor: KiteColors.accent,
              side: const BorderSide(color: KiteColors.accent),
            ),
          ),
        ],
      ),
    );
  }
}