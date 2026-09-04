import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'conversation_screen.dart';
import 'global_search_screen.dart';
import '../chat_lock.dart';
import 'notif_defaults_screen.dart';

/// Écran principal : liste des discussions (miroir de screens/chat-list.html).
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.api,
    this.shell,
    this.onRefresh,
    this.onChatSelected,
  });

  final KiteApi api;

  /// Données injectées depuis le shell (si null, fetch indépendant).
  final AppShell? shell;
  final Future<void> Function()? onRefresh;

  /// Callback pour la vue adaptative 2 panneaux : notifie le shell quand
  /// une discussion est sélectionnée (au lieu de naviguer).
  final void Function(Chat chat)? onChatSelected;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  Future<List<Chat>>? _future;
  String _filter = 'Toutes';
  bool _showArchived = false;

  // Dossiers (façon Telegram) : chargés depuis l'API/store, id sélectionné.
  List<ChatFolder> _folders = [];
  String? _activeFolderId;

  bool get _injected => widget.shell != null;

  @override
  void initState() {
    super.initState();
    ChatLockStore.instance.addListener(_refresh);
    if (!_injected) {
      _future = widget.api.fetchChats();
    }
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    try {
      final f = await widget.api.fetchFolders();
      if (mounted) setState(() => _folders = f);
    } catch (_) {
      // dossiers indisponibles : la liste reste fonctionnelle sans
    }
  }

  /// Recharge les dossiers après une mutation (create/rename/delete/membership).
  Future<void> _mutateFolder(Future<void> Function() action) async {
    await action();
    await _loadFolders();
  }

  @override
  void dispose() {
    ChatLockStore.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (_injected) {
      widget.onRefresh?.call();
      return;
    }
    setState(() {
      _future = widget.api.fetchChats();
    });
  }

  List<Chat> _applyFilter(List<Chat> chats) {
    final me = widget.api.meId;
    // Vue « Archivées » : uniquement les conversations que J'ai archivées.
    if (_showArchived) {
      return chats.where((c) => c.archivedFor(me)).toList();
    }
    // Vue normale : masque mes conversations archivées (les discussions
    // supprimées « pour moi » sont déjà filtrées par l'API/store).
    chats = chats.where((c) => !c.archivedFor(me)).toList();
    // Dossier actif : uniquement ses conversations (dans l'ordre du dossier).
    final active = _folders.where((f) => f.id == _activeFolderId).toList();
    if (active.isNotEmpty) {
      final ids = active.first.chatIds.toSet();
      chats = chats.where((c) => ids.contains(c.id)).toList();
    }
    switch (_filter) {
      case 'Non lues':
        return chats.where((c) => c.unread > 0).toList();
      case 'Groupes':
        return chats.where((c) => c.isGroup).toList();
      default:
        // Épinglées d'abord, puis par dernier message (comportement WhatsApp).
        return chats
          ..sort((a, b) {
            final pa = a.pinnedFor(me) ? 0 : 1;
            final pb = b.pinnedFor(me) ? 0 : 1;
            if (pa != pb) return pa - pb;
            final ta = a.lastMessage?.createdAt ?? 0;
            final tb = b.lastMessage?.createdAt ?? 0;
            if (ta != tb) return tb - ta;
            return a.name.compareTo(b.name);
          });
    }
  }

  Future<void> _toggleArchive(BuildContext context, Chat chat) async {
    final target = !chat.archivedFor(widget.api.meId);
    try {
      await widget.api.setChatArchived(chat.id, archived: target);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Action indisponible')));
      }
      return;
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            if (_showArchived)
              Material(
                color: KiteColors.surface2,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.inventory_2,
                      size: 18, color: KiteColors.tint2),
                  title: const Text('Archivées',
                      style: TextStyle(fontSize: 13, color: KiteColors.fg)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: KiteColors.muted),
                    onPressed: () => setState(() => _showArchived = false),
                  ),
                ),
              ),
            if (!_showArchived) _filtersRow(),
            Expanded(child: _chatList(context)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'fab-chat-list',
        backgroundColor: KiteColors.accent,
        foregroundColor: KiteColors.accentInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => _newChat(context),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Discussions',
              style: TextStyle(
                fontFamilyFallback: kDisplayFont,
                fontSize: 26,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Rechercher',
            onPressed: () => _openSearch(context),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'Options',
            onPressed: () => _showOptions(context),
          ),
        ],
      ),
    );
  }

  Widget _filtersRow() {
    // Rangée façon Telegram : Toutes · Non lues (compteur) · dossiers · +.
    final chats0 = _injected ? (widget.shell?.chats ?? const <Chat>[]) : null;
    int unreadCount = 0;
    if (chats0 != null) {
      final me = widget.api.meId;
      unreadCount =
          chats0.where((c) => !c.archivedFor(me) && c.unread > 0).length;
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _folderTab(
            label: 'Toutes',
            selected: _activeFolderId == null && _filter == 'Toutes',
            onTap: () => setState(() {
              _activeFolderId = null;
              _filter = 'Toutes';
            }),
          ),
          _folderTab(
            label: 'Non lues',
            count: unreadCount,
            selected: _activeFolderId == null && _filter == 'Non lues',
            onTap: () => setState(() {
              _activeFolderId = null;
              _filter = 'Non lues';
            }),
          ),
          for (final f in _folders)
            _folderTab(
              label: f.name,
              count: _folderUnread(f),
              selected: _activeFolderId == f.id,
              onTap: () => setState(() {
                _activeFolderId = _activeFolderId == f.id ? null : f.id;
              }),
              onLongPress: () => _editFolder(f),
            ),
          _folderTab(
            label: '+',
            selected: false,
            onTap: _createFolder,
          ),
        ],
      ),
    );
  }

  Widget _folderTab({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    int count = 0,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: selected
                ? KiteColors.accent.withValues(alpha: 0.16)
                : KiteColors.surface,
            border: Border.all(
              color: selected
                  ? KiteColors.accent.withValues(alpha: 0.5)
                  : KiteColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? KiteColors.accent : KiteColors.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: const TextStyle(
                    color: KiteColors.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  int _folderUnread(ChatFolder f) {
    final chats0 = _injected ? (widget.shell?.chats ?? const <Chat>[]) : null;
    if (chats0 == null) return 0;
    final ids = f.chatIds.toSet();
    return chats0.where((c) => ids.contains(c.id) && c.unread > 0).length;
  }

  // ---------- Gestion des dossiers ----------

  Widget _chatList(BuildContext context) {
    final chats0 = _injected ? (widget.shell?.chats ?? const <Chat>[]) : null;
    if (chats0 != null) {
      final chats = _applyFilter(chats0);
      if (chats.isEmpty) {
        return const _EmptyState();
      }
      return RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: chats.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: KiteColors.border),
          itemBuilder: (context, i) => _ChatRow(
            chat: chats[i],
            pinned: chats[i].pinnedFor(widget.api.meId),
            muted: chats[i].mutedFor(widget.api.meId),
            locked: ChatLockStore.instance.isLocked(chats[i].id),
            onTap: () => _openChat(context, chats[i]),
            onLongPress: () => _showChatMenu(context, chats[i]),
          ),
        ),
      );
    }
    return FutureBuilder<List<Chat>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorState(
            message: 'Impossible de joindre le serveur.\n${snap.error}',
            onRetry: _refresh,
          );
        }
        final chats = _applyFilter(snap.data ?? []);
        if (chats.isEmpty) {
          return const _EmptyState();
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: chats.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: KiteColors.border),
            itemBuilder: (context, i) => _ChatRow(
              chat: chats[i],
              pinned: chats[i].pinnedFor(widget.api.meId),
              muted: chats[i].mutedFor(widget.api.meId),
              locked: ChatLockStore.instance.isLocked(chats[i].id),
              onTap: () => _openChat(context, chats[i]),
              onLongPress: () => _showChatMenu(context, chats[i]),
            ),
          ),
        );
      },
    );
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            GlobalSearchScreen(api: widget.api, shell: widget.shell),
      ),
    );
  }

  void _showOptions(BuildContext context) {
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
            ListTile(
              leading:
                  const Icon(Icons.edit_outlined, color: KiteColors.accent),
              title: const Text('Nouvelle discussion',
                  style: TextStyle(color: KiteColors.fg)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _newChat(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined,
                  color: KiteColors.accent),
              title: const Text('Notifications',
                  style: TextStyle(color: KiteColors.fg)),
              subtitle: const Text('Défauts pour toutes les conversations',
                  style: TextStyle(fontSize: 12, color: KiteColors.muted)),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => NotifDefaultsScreen(api: widget.api)),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.inventory_2_outlined,
                color: _showArchived ? KiteColors.tint2 : KiteColors.accent,
              ),
              title: Text(
                _showArchived ? 'Retour aux discussions' : 'Archivées',
                style: const TextStyle(color: KiteColors.fg),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                setState(() => _showArchived = !_showArchived);
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline, color: KiteColors.danger),
              title: const Text('Verrouiller l’application',
                  style: TextStyle(color: KiteColors.fg)),
              onTap: () {
                Navigator.pop(sheetCtx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Verrouillage bientôt disponible')));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Boîte de dialogue : ajoute/retire la discussion des dossiers existants.
  Future<void> _chooseFolderForChat(BuildContext context, Chat chat) async {
    if (_folders.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Créez d’abord un dossier (onglet +)')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Dossiers', style: TextStyle(color: KiteColors.fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in _folders)
              StatefulBuilder(
                builder: (ctx, setLocal) {
                  final member = f.chatIds.contains(chat.id);
                  return CheckboxListTile(
                    value: member,
                    activeColor: KiteColors.accent,
                    title: Text(f.name, style: const TextStyle(color: KiteColors.fg)),
                    onChanged: (_) async {
                      await _mutateFolder(() => widget.api
                          .folderMembership(f.id, chat.id, add: !member));
                      setLocal(() {});
                    },
                  );
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Nouveau dossier', style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration:
              const InputDecoration(hintText: 'ex. Travail, Famille, Clients'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Créer')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await _mutateFolder(() => widget.api.createFolder(name));
      if (mounted) {
        setState(() {
          _activeFolderId = _folders.isNotEmpty ? _folders.last.id : null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Impossible de créer le dossier : $e')));
      }
    }
  }

  Future<void> _editFolder(ChatFolder f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.edit_outlined, color: KiteColors.accent),
              title: const Text('Renommer le dossier'),
              onTap: () => Navigator.pop(sheetCtx, 'rename'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: KiteColors.danger),
              title: const Text('Supprimer le dossier'),
              onTap: () => Navigator.pop(sheetCtx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: f.name);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: KiteColors.surface,
          title: const Text('Renommer', style: TextStyle(fontSize: 17)),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Renommer')),
          ],
        ),
      );
      if (name == null || name.isEmpty || name == f.name) return;
      await _mutateFolder(() => widget.api.renameFolder(f.id, name));
    } else {
      await _mutateFolder(() => widget.api.deleteFolder(f.id));
      if (mounted && _activeFolderId == f.id) {
        setState(() => _activeFolderId = null);
      }
    }
  }

  void _openChat(BuildContext context, Chat chat) {
    if (widget.onChatSelected != null) {
      widget.onChatSelected!(chat);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          api: widget.api,
          chat: chat,
        ),
      ),
    );
  }

  void _showChatMenu(BuildContext context, Chat chat) {
    final me = widget.api.meId;
    final archived = chat.archivedFor(me);
    final pinned = chat.pinnedFor(me);
    final muted = chat.mutedFor(me);
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
            ListTile(
              leading: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: KiteColors.accent,
              ),
              title: Text(
                pinned
                    ? (chat.isGroup
                        ? 'Détacher le groupe'
                        : 'Détacher la discussion')
                    : (chat.isGroup
                        ? 'Épingler le groupe'
                        : 'Épingler la discussion'),
                style: const TextStyle(color: KiteColors.fg),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _togglePin(context, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined,
                  color: KiteColors.accent),
              title: Text(archived ? 'Désarchiver' : 'Archiver',
                  style: const TextStyle(color: KiteColors.fg)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _toggleArchive(context, chat);
              },
            ),
            ListTile(
              leading: Icon(
                muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                color: KiteColors.accent,
              ),
              title: Text(
                muted ? 'Réactiver les notifications' : 'Mettre en sourdine',
                style: const TextStyle(color: KiteColors.fg),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                muted
                    ? _unmute(context, chat)
                    : _chooseMuteDuration(context, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined, color: KiteColors.accent),
              title: const Text('Dossiers',
                  style: TextStyle(color: KiteColors.fg)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _chooseFolderForChat(context, chat);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: KiteColors.danger),
              title: const Text('Supprimer la discussion',
                  style: TextStyle(color: KiteColors.danger)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(context, chat);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Choix de la durée de sourdine (8 h / 1 semaine / toujours).
  Future<void> _chooseMuteDuration(BuildContext context, Chat chat) async {
    final duration = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, label) in [
              ('8h', 'Pendant 8 heures'),
              ('1w', 'Pendant 1 semaine'),
              ('always', 'Toujours'),
            ])
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined,
                    color: KiteColors.accent),
                title:
                    Text(label, style: const TextStyle(color: KiteColors.fg)),
                onTap: () => Navigator.pop(sheetCtx, value),
              ),
          ],
        ),
      ),
    );
    if (duration == null) return;
    try {
      await widget.api.setChatMuted(chat.id, duration: duration);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Action indisponible')));
      }
      return;
    }
    _refresh();
  }

  Future<void> _unmute(BuildContext context, Chat chat) async {
    try {
      await widget.api.setChatMuted(chat.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Action indisponible')));
      }
      return;
    }
    _refresh();
  }

  Future<void> _togglePin(BuildContext context, Chat chat) async {
    final target = !chat.pinnedFor(widget.api.meId);
    try {
      await widget.api.setChatPinned(chat.id, pinned: target);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Action indisponible')));
      }
      return;
    }
    _refresh();
  }

  /// Confirmation avant suppression (pour moi) — irréversible pour
  /// l'utilisateur tant qu'aucun nouveau message n'arrive.
  Future<void> _confirmDelete(BuildContext context, Chat chat) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: KiteColors.surface,
        title: const Text('Supprimer la discussion ?'),
        content: Text(
          chat.isGroup
              ? 'Le groupe quittera votre liste. Un nouveau message le fera réapparaître.'
              : 'La discussion quittera votre liste. Un nouveau message la fera réapparaître.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('Supprimer',
                style: TextStyle(color: KiteColors.danger)),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await widget.api.deleteChat(chat.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Suppression impossible')));
      }
      return;
    }
    _refresh();
  }

  /// Nouvelle discussion : choisit un contact et crée (ou réutilise) la DM.
  void _newChat(BuildContext context) {
    final shell = widget.shell;
    final contacts = shell == null
        ? const <User>[]
        : shell.users.where((u) => u.id != widget.api.meId).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Nouvelle discussion',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: KiteColors.fg)),
            ),
            if (contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Aucun contact disponible',
                    style: TextStyle(color: KiteColors.muted)),
              ),
            for (final u in contacts)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: KiteColors.surface2,
                  child: Text(u.name.isNotEmpty ? u.name[0] : '?',
                      style:
                          const TextStyle(fontSize: 13, color: KiteColors.fg)),
                ),
                title:
                    Text(u.name, style: const TextStyle(color: KiteColors.fg)),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  // DM existante avec ce contact ? On l'ouvre simplement.
                  final existing = (shell?.chats ?? const <Chat>[]).where((c) {
                    return !c.isGroup &&
                        c.memberIds.contains(u.id) &&
                        c.memberIds.contains(widget.api.meId);
                  }).firstOrNull;
                  if (existing != null) {
                    _openChat(context, existing);
                    return;
                  }
                  try {
                    final chat =
                        await widget.api.createChat('dm', u.name, [u.id]);
                    _refresh();
                    if (context.mounted) _openChat(context, chat);
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Création impossible')));
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.onTap,
    required this.onLongPress,
    this.pinned = false,
    this.muted = false,
    this.locked = false,
  });

  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool pinned;
  final bool muted;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final initials = chat.name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    // Verrouillée : l'aperçu ne divulgue rien (masqué, même si la
    // conversation est déverrouillée dans une autre vue).
    final lockedNow = locked || ChatLockStore.instance.isLocked(chat.id);
    final preview = lockedNow
        ? 'Discussion verrouillée · touchez pour ouvrir'
        : (chat.lastMessage?.preview() ?? 'Nouvelle discussion');
    final time =
        chat.lastMessage == null ? '' : _timeOf(chat.lastMessage!.createdAt);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            _Avatar(initials: initials, group: chat.isGroup),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (pinned) ...[
                        const Icon(Icons.push_pin,
                            size: 13, color: KiteColors.muted),
                        const SizedBox(width: 4),
                      ],
                      if (lockedNow) ...[
                        const Icon(Icons.lock,
                            size: 13, color: KiteColors.muted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(time,
                          style: const TextStyle(
                              color: KiteColors.muted, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: KiteColors.muted, fontSize: 14),
                  ),
                ],
              ),
            ),
            if (muted) ...[
              const SizedBox(width: 6),
              const Icon(Icons.notifications_off,
                  size: 14, color: KiteColors.muted),
            ],
            if (chat.unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: muted ? KiteColors.muted : KiteColors.accent,
                  borderRadius: const BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  '${chat.unread}',
                  style: TextStyle(
                      color: muted ? KiteColors.bg : KiteColors.accentInk,
                      fontSize: 11,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
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
  const _Avatar({required this.initials, required this.group});

  final String initials;
  final bool group;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(group ? 16 : 24),
        border: Border.all(color: KiteColors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 44, color: KiteColors.muted),
          SizedBox(height: 10),
          Text('Aucune discussion', style: TextStyle(color: KiteColors.muted)),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

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
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: KiteColors.muted)),
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
