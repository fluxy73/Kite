import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';

/// Appel entrant en cours de sonnerie.
class IncomingCall {
  const IncomingCall({
    required this.id,
    required this.callerName,
    required this.chatId,
    this.kind = 'audio',
  });

  final String id;
  final String callerName;
  final String chatId;
  final String kind;

  bool get isVideo => kind == 'video';

  factory IncomingCall.fromEvent(ServerEvent ev) {
    final d = ev.data;
    return IncomingCall(
      id: d['id']?.toString() ?? '',
      callerName: d['callerName']?.toString() ?? 'Inconnu',
      chatId: d['chatId']?.toString() ?? '',
      kind: d['kind']?.toString() ?? 'audio',
    );
  }
}

/// Centrale d'appels : écoute le flux temps réel (WebSocket/SSE) et expose
/// l'appel entrant courant via un ValueNotifier global.
class CallCenter {
  CallCenter._();
  static final CallCenter instance = CallCenter._();

  final ValueNotifier<IncomingCall?> current = ValueNotifier<IncomingCall?>(null);

  /// Incrémenté quand un appel expire (manqué) : le shell recharge la liste des appels.
  final ValueNotifier<int> callsRevision = ValueNotifier<int>(0);
  StreamSubscription<ServerEvent>? _sub;
  final Set<String> _seen = {};

  void start(dynamic api) {
    if (_sub != null) return;
    _sub = api.realtime().listen(_onEvent, onError: (_) {});
  }

  void _onEvent(ServerEvent ev) {
    if (ev.type != 'call') return;
    final call = IncomingCall.fromEvent(ev);
    if (call.id.isEmpty || _seen.contains(call.id)) return;
    _seen.add(call.id);
    current.value = call;
  }

  void dismiss() {
    current.value = null;
  }

  /// Notifie qu'un appel a expiré (manqué) pour rafraîchir la section Récents.
  void notifyMissed() {
    callsRevision.value++;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    current.dispose();
  }
}
