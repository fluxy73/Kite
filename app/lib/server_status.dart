import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';

/// État de connexion au serveur Go.
enum ServerConn { online, offline, connecting }

/// Sonde de connectivité : en mode serveur, interroge GET /api/health toutes
/// les 10 s. En mode hors-ligne (API locale, pas de KiteApi), il n'y a aucun
/// serveur à sonder : état « offline » immédiat, aucun timer.
class ServerStatus {
  ServerStatus._();
  static final ServerStatus instance = ServerStatus._();

  final ValueNotifier<ServerConn> state = ValueNotifier<ServerConn>(ServerConn.connecting);

  /// true si l'app tourne sans serveur (API locale) — le badge affiche
  /// « Hors ligne » en neutre (mode normal) et non en erreur.
  bool offlineMode = false;

  Timer? _timer;
  dynamic _api;

  /// Démarre la sonde. Avec une API hors-ligne, aucun probing n'a lieu.
  void start(dynamic api) {
    _api = api;
    offlineMode = api is! KiteApi;
    _timer?.cancel();
    if (offlineMode) {
      state.value = ServerConn.offline;
      return;
    }
    state.value = ServerConn.connecting;
    probe();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => probe());
  }

  /// Interroge /api/health et met à jour l'état. Public pour les tests.
  Future<void> probe() async {
    if (offlineMode) return;
    if (state.value != ServerConn.online) {
      state.value = ServerConn.connecting;
    }
    try {
      await (_api as KiteApi).pingHealth();
      state.value = ServerConn.online;
    } catch (_) {
      state.value = ServerConn.offline;
    }
  }

  /// Arrête la sonde (tests).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Pastille visible en permanence (barre d'onglets) : état de connexion au
/// serveur Go — vert « En ligne », orange « Connexion… », rouge « Hors ligne »
/// (serveur injoignable) ou gris « Hors ligne » (mode local sans serveur).
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ServerConn>(
      valueListenable: ServerStatus.instance.state,
      builder: (context, conn, _) {
        final local = ServerStatus.instance.offlineMode;
        final (color, label) = switch (conn) {
          ServerConn.online => (const Color(0xFF34C759), 'En ligne'),
          ServerConn.connecting => (const Color(0xFFFF9F0A), 'Connexion…'),
          ServerConn.offline when local => (KiteColors.muted, 'Hors ligne'),
          ServerConn.offline => (KiteColors.danger, 'Hors ligne'),
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: KiteColors.surface2,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: KiteColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 11, color: KiteColors.fg)),
            ],
          ),
        );
      },
    );
  }
}
