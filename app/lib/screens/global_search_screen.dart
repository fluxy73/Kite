import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'conversation_screen.dart';

/// Recherche globale RÉELLE : fetch les discussions + messages (serveur ou
/// base locale via l'API injectée) et filtre côté client par requête.
/// Résultats : conversations (nom) et messages (texte, avec expéditeur/chat).
class GlobalSearchScreen extends StatefulWidget {
  const GlobalSearchScreen({super.key, required this.api, this.shell});

  final KiteApi api;
  final AppShell? shell;

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  String _query = '';
  List<Chat>? _chats;
  List<_MessageHit>? _messages;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final shell = widget.shell ?? await widget.api.fetchAppShell();
      final chats = shell.chats;
      final hits = <_MessageHit>[];
      final names = {for (final u in shell.users) u.id: u.name};
      for (final c in chats) {
        final msgs = await widget.api.fetchMessages(c.id);
        for (final m in msgs) {
          if (m.text.isNotEmpty && m.visibleTo(widget.api.meId)) {
            hits.add(_MessageHit(
              message: m,
              chat: c,
              senderName: m.senderId == widget.api.meId
                  ? 'Moi'
                  : (names[m.senderId] ?? m.senderId),
            ));
          }
        }
      }
      if (mounted) {
        setState(() {
          _chats = chats;
          _messages = hits;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  List<Chat> get _chatResults {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty || _chats == null) return const [];
    return _chats!.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  List<_MessageHit> get _messageResults {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty || _messages == null) return const [];
    return _messages!
        .where((h) => h.message.text.toLowerCase().contains(q))
        .toList();
  }

  void _openHit(BuildContext context, Chat chat) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(api: widget.api, chat: chat),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KiteColors.bg,
      appBar: AppBar(
        backgroundColor: KiteColors.bg,
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Rechercher messages, discussions…',
            border: InputBorder.none,
          ),
          onChanged: (q) => setState(() => _query = q),
        ),
      ),
      body: _error != null
          ? Center(
              child: Text('Recherche impossible\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: KiteColors.muted)),
            )
          : _buildResults(),
    );
  }

  Widget _buildResults() {
    if (_query.trim().isEmpty) {
      return const Center(
        child: Text('Tapez pour rechercher',
            style: TextStyle(color: KiteColors.muted)),
      );
    }
    final chats = _chatResults;
    final messages = _messageResults;
    if (_chats == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (chats.isEmpty && messages.isEmpty) {
      return const Center(
        child: Text('Aucun résultat', style: TextStyle(color: KiteColors.muted)),
      );
    }
    return ListView(
      children: [
        if (chats.isNotEmpty) ...[
          const _SectionLabel('Discussions'),
          for (final c in chats)
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline, color: KiteColors.tint2),
              title: Text(c.name, style: const TextStyle(color: KiteColors.fg)),
              subtitle: c.lastMessage?.text != null
                  ? Text(c.lastMessage!.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: KiteColors.muted, fontSize: 12))
                  : null,
              onTap: () => _openHit(context, c),
            ),
        ],
        if (messages.isNotEmpty) ...[
          const _SectionLabel('Messages'),
          for (final h in messages)
            ListTile(
              leading: const Icon(Icons.notes, color: KiteColors.muted),
              title: Text(h.message.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: KiteColors.fg)),
              subtitle: Text('${h.senderName} · ${h.chat.name}',
                  style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
              onTap: () => _openHit(context, h.chat),
            ),
        ],
      ],
    );
  }
}

class _MessageHit {
  const _MessageHit({required this.message, required this.chat, required this.senderName});
  final Message message;
  final Chat chat;
  final String senderName;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(label.toUpperCase(),
          style: const TextStyle(
              color: KiteColors.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
    );
  }
}
