import 'package:flutter/material.dart';

import '../api.dart';
import '../call_center.dart';
import '../models.dart';
import '../server_status.dart';
import '../theme.dart';
import 'calls_screen.dart';
import 'chat_list_screen.dart';
import 'conversation_screen.dart';

/// Enveloppe à onglets (Discussions / Appels) branchée sur le payload agrégé
/// GET /api/shell du serveur Go. Sur écrans larges, l'onglet Discussions passe
/// en vue 2 panneaux (liste + conversation côte à côte).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.api});
  final KiteApi api;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  Chat? _selectedChat; // sélection pour la vue 2 panneaux (écrans larges)
  AppShell? _shell;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    CallCenter.instance.callsRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    CallCenter.instance.callsRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shell = await widget.api.fetchAppShell();
      if (mounted) {
        setState(() {
          _shell = shell;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _shell == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null && _shell == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 44, color: KiteColors.danger),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: KiteColors.muted)),
              ),
              FilledButton.icon(
                onPressed: _load,
                // not const: onPressed est une méthode d'instance
                
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }

    final shell = _shell ?? const AppShell();
    final unreadTotal = shell.chats.fold<int>(0, (sum, c) => sum + c.unread);
    final screens = [
      ChatListScreen(api: widget.api, shell: shell, onRefresh: _load),
      CallsScreen(api: widget.api, shell: shell, onRefresh: _load),
    ];

    // Vue adaptative : sur écrans larges (>= 900 px logiques) l'onglet Discussions
    // affiche la liste et la conversation côte à côte (2 panneaux).
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        if (isWide) {
          return Scaffold(
            body: SafeArea(
              child: _tab == 0
                  ? _twoPaneDiscussions(shell)
                  : IndexedStack(index: _tab - 1, children: screens.skip(1).toList()),
            ),
            bottomNavigationBar: _tabBar(unreadTotal),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: IndexedStack(
              index: _tab,
              children: screens,
            ),
          ),
          bottomNavigationBar: _tabBar(unreadTotal),
        );
      },
    );
  }

  /// Vue 2 panneaux : liste des discussions à gauche, conversation à droite.
  Widget _twoPaneDiscussions(AppShell shell) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 380,
          child: ChatListScreen(
            api: widget.api,
            shell: shell,
            onRefresh: _load,
            onChatSelected: (chat) => setState(() => _selectedChat = chat),
          ),
        ),
        const VerticalDivider(width: 1, color: KiteColors.border),
        Expanded(
          child: _selectedChat != null
              ? ConversationScreen(api: widget.api, chat: _selectedChat!)
              : const Center(
                  child: Text(
                    'Sélectionnez une discussion',
                    style: TextStyle(color: KiteColors.muted),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _tabBar(int unreadTotal) {
    return Container(
      decoration: const BoxDecoration(
        color: KiteColors.bg,
        border: Border(top: BorderSide(color: KiteColors.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      // L'indicateur est posé en surimpression dans le coin : il ne comprime
      // jamais les onglets, quelle que soit la largeur d'écran.
      child: Stack(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _tabItem(0, Icons.chat_bubble_outline, 'Discussions',
                  badge: unreadTotal > 0 ? '$unreadTotal' : null),
              _tabItem(1, Icons.call_outlined, 'Appels'),
            ],
          ),
          const Positioned(top: 0, right: 10, child: ConnectionBadge()),
        ],
      ),
    );
  }

  Widget _tabItem(int index, IconData icon, String label, {String? badge}) {
    final active = _tab == index;
    final color = active ? KiteColors.accent : KiteColors.muted;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: color, size: 22),
                if (badge != null)
                  Positioned(
                    top: -5,
                    right: -9,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: KiteColors.danger,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      child: Text(badge,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 10, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}