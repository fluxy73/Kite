import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'conversation_screen.dart';

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

  static const _filters = ['Toutes', 'Non lues', 'Favoris', 'Groupes'];

  bool get _injected => widget.shell != null;

  @override
  void initState() {
    super.initState();
    if (!_injected) {
      _future = widget.api.fetchChats();
    }
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
    switch (_filter) {
      case 'Non lues':
        return chats.where((c) => c.unread > 0).toList();
      case 'Groupes':
        return chats.where((c) => c.isGroup).toList();
      default:
        return chats;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(context),
            _filtersRow(),
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
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final f in _filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(f),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
                showCheckmark: false,
                backgroundColor: KiteColors.surface,
                selectedColor: KiteColors.accent.withValues(alpha: 0.16),
                side: BorderSide(
                  color: _filter == f
                      ? KiteColors.accent.withValues(alpha: 0.5)
                      : KiteColors.border,
                ),
                labelStyle: TextStyle(
                  color: _filter == f ? KiteColors.accent : KiteColors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chatList(BuildContext context) {
    final chats0 = _injected
        ? (widget.shell?.chats ?? const <Chat>[])
        : null;
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
              onTap: () => _openChat(context, chats[i]),
              onLongPress: () => _showChatMenu(context, chats[i]),
            ),
          ),
        );
      },
    );
  }

  void _openSearch(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KiteColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
        ),
        child: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Rechercher messages, contacts…'),
          onSubmitted: (q) {
            Navigator.pop(sheetCtx);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Recherche « $q » — workflow simulé')),
            );
          },
        ),
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
            for (final item in const ['Nouvelle discussion', 'Nouveau groupe', 'Archivées', 'Paramètres', 'Verrouiller l’application'])
              ListTile(
                leading: Icon(
                  switch (item) {
                    'Nouvelle discussion' => Icons.edit_outlined,
                    'Nouveau groupe' => Icons.group_add_outlined,
                    'Archivées' => Icons.inventory_2_outlined,
                    'Paramètres' => Icons.settings_outlined,
                    _ => Icons.lock_outline,
                  },
                  color: item == 'Verrouiller l’application'
                      ? KiteColors.danger
                      : KiteColors.accent,
                ),
                title: Text(item, style: const TextStyle(color: KiteColors.fg)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$item — workflow simulé')),
                  );
                },
              ),
          ],
        ),
      ),
    );
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
              leading: const Icon(Icons.push_pin_outlined, color: KiteColors.accent),
              title: Text(chat.isGroup ? 'Épingler le groupe' : 'Épingler la discussion'),
              onTap: () => Navigator.pop(sheetCtx),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined, color: KiteColors.accent),
              title: const Text('Mettre en sourdine', style: TextStyle(color: KiteColors.fg)),
              onTap: () => Navigator.pop(sheetCtx),
            ),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined, color: KiteColors.accent),
              title: const Text('Archiver', style: TextStyle(color: KiteColors.fg)),
              onTap: () => Navigator.pop(sheetCtx),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: KiteColors.danger),
              title: const Text('Supprimer la discussion', style: TextStyle(color: KiteColors.danger)),
              onTap: () => Navigator.pop(sheetCtx),
            ),
          ],
        ),
      ),
    );
  }

  void _newChat(BuildContext context) {
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
            const ListTile(
              leading: Icon(Icons.person_add_alt, color: KiteColors.accent),
              title: Text('Nouvelle discussion', style: TextStyle(color: KiteColors.fg)),
            ),
            const ListTile(
              leading: Icon(Icons.group_add_outlined, color: KiteColors.accent),
              title: Text('Nouveau groupe', style: TextStyle(color: KiteColors.fg)),
            ),
            ListTile(
              leading: const Icon(Icons.search, color: KiteColors.accent),
              title: const Text('Rechercher des contacts', style: TextStyle(color: KiteColors.fg)),
              onTap: () => Navigator.pop(sheetCtx),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.chat, required this.onTap, required this.onLongPress});

  final Chat chat;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final initials = chat.name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final preview = chat.lastMessage?.preview() ?? 'Nouvelle discussion';
    final time = chat.lastMessage == null ? '' : _timeOf(chat.lastMessage!.createdAt);
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
                      Expanded(
                        child: Text(
                          chat.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(time, style: const TextStyle(color: KiteColors.muted, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KiteColors.muted, fontSize: 14),
                  ),
                ],
              ),
            ),
            if (chat.unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: const BoxDecoration(
                  color: KiteColors.accent,
                  borderRadius: BorderRadius.all(Radius.circular(999)),
                ),
                child: Text(
                  '${chat.unread}',
                  style: const TextStyle(color: KiteColors.accentInk, fontSize: 11, fontWeight: FontWeight.w700),
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
