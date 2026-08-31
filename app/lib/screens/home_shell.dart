import 'package:flutter/material.dart';

import '../api.dart';
import '../call_center.dart';
import '../models.dart';
import '../theme.dart';
import 'calls_screen.dart';
import 'chat_list_screen.dart';
import 'communities_screen.dart';

/// Enveloppe à onglets (Discussions / Communautés / Appels) branchée sur le\n///payload agrégé GET /api/shell du serveur Go.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.api});
  final KiteApi api;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
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
    final screens = [
      ChatListScreen(api: widget.api, shell: shell, onRefresh: _load),
      CommunitiesScreen(api: widget.api, shell: shell, onRefresh: _load),
      CallsScreen(api: widget.api, shell: shell, onRefresh: _load),
    ];

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: screens,
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: KiteColors.bg,
          border: Border(top: BorderSide(color: KiteColors.border)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _tabItem(0, Icons.chat_bubble_outline, 'Discussions'),
            _tabItem(1, Icons.grid_view_outlined, 'Communautés'),
            _tabItem(2, Icons.call_outlined, 'Appels'),
          ],
        ),
      ),
    );
  }

  Widget _tabItem(int index, IconData icon, String label) {
    final active = _tab == index;
    final color = active ? KiteColors.accent : KiteColors.muted;
    return InkWell(
      onTap: () => setState(() => _tab = index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 10, color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}