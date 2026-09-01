import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';

/// Rappels locaux : notifie quand un appel planifié (rappel activé) est
/// à une heure ou moins de l'échéance.
class ScheduledReminderCenter {
  ScheduledReminderCenter._();
  static final ScheduledReminderCenter instance = ScheduledReminderCenter._();

  /// L'appel planifié à notifier (une seule entrée à la fois).
  final ValueNotifier<ScheduledCall?> next = ValueNotifier<ScheduledCall?>(null);

  final Set<String> _notified = {};
  Timer? _timer;
  KiteApi? _api;

  /// Intervalle de vérification et fenêtre de rappel (1 h).
  static const _tick = Duration(seconds: 30);
  static const _window = Duration(hours: 1);

  void start(dynamic api) {
    _api = api;
    _timer ??= Timer.periodic(_tick, (_) => _check());
    _check();
  }

  Future<void> _check() async {
    final api = _api;
    if (api == null) return;
    try {
      final calls = await api.fetchScheduledCalls();
      final now = DateTime.now().millisecondsSinceEpoch;
      ScheduledCall? due;
      for (final sc in calls) {
        if (!sc.reminder || _notified.contains(sc.id)) continue;
        final delta = sc.scheduledAt - now;
        if (delta > 0 && delta <= _window.inMilliseconds) {
          // prend le plus proche à notifier
          if (due == null || sc.scheduledAt < due.scheduledAt) due = sc;
        }
      }
      if (due != null) {
        _notified.add(due.id);
        next.value = due;
      }
    } catch (_) {
      // serveur injoignable : on réessaiera au prochain tick
    }
  }

  /// Consomme la notification (après affichage).
  void reset() {
    next.value = null;
  }

  /// Arrête la vérification périodique (utilisé par les tests).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
