import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';

/// Appel entrant en cours de sonnerie.
class IncomingCall {
  const IncomingCall({
    required this.id,
    required this.callerName,
    required this.chatId,
    this.kind = 'audio',
    this.group = false,
  });

  final String id;
  final String callerName;
  final String chatId;
  final String kind;
  final bool group; // true = appel de groupe (écran simulé), false = 1:1 WebRTC

  bool get isVideo => kind == 'video';

  factory IncomingCall.fromEvent(ServerEvent ev) {
    final d = ev.data;
    return IncomingCall(
      id: d['id']?.toString() ?? '',
      callerName: d['callerName']?.toString() ?? 'Inconnu',
      chatId: d['chatId']?.toString() ?? '',
      kind: d['kind']?.toString() ?? 'audio',
      group: d['group'] as bool? ?? false,
    );
  }
}

/// Signal WebRTC relayé par le serveur (offer | answer | ice).
class CallSignalEvent {
  const CallSignalEvent({
    required this.callId,
    required this.kind,
    required this.from,
    required this.payload,
  });

  final String callId;
  final String kind; // offer | answer | ice
  final String from;
  final Map<String, dynamic> payload;
}

/// Centrale d'appels : écoute le flux temps réel (WebSocket/SSE) et expose
/// l'appel entrant courant ainsi que les flux de signalisation WebRTC
/// (call_signal) et de réponse (call_respond) via des streams globaux.
class CallCenter {
  CallCenter._();
  static final CallCenter instance = CallCenter._();

  final ValueNotifier<IncomingCall?> current = ValueNotifier<IncomingCall?>(null);

  /// Incrémenté quand un appel expire (manqué) : le shell recharge la liste des appels.
  final ValueNotifier<int> callsRevision = ValueNotifier<int>(0);

  /// Signaux WebRTC entrants (offer/answer/ICE), tous appels confondus.
  final _signals = StreamController<CallSignalEvent>.broadcast();

  /// Réponses d'appel (accepted/declined/missed/ended) broadcastées par le serveur.
  final _responses = StreamController<Map<String, dynamic>>.broadcast();

  /// Backlog des signaux par appel : un moteur qui s'abonne en retard (ex.
  /// écran d'appel pas encore monté quand l'offer part) les rejoue à l'init.
  final Map<String, List<CallSignalEvent>> _backlog = {};
  static const _backlogPerCall = 30;
  static const _backlogCallsMax = 8;

  Stream<CallSignalEvent> get signals => _signals.stream;
  Stream<Map<String, dynamic>> get responses => _responses.stream;

  /// Signaux déjà reçus pour un appel (replay à l'abonnement du moteur).
  List<CallSignalEvent> signalBacklog(String callId) =>
      List.unmodifiable(_backlog[callId] ?? const []);

  StreamSubscription<ServerEvent>? _sub;
  final Set<String> _seen = {};

  void start(dynamic api) {
    if (_sub != null) return;
    _sub = api.realtime().listen(handleEvent, onError: (_) {});
  }

  /// Traite un événement temps réel (public pour les tests).
  @visibleForTesting
  void handleEvent(ServerEvent ev) {
    switch (ev.type) {
      case 'call':
        final call = IncomingCall.fromEvent(ev);
        if (call.id.isEmpty || _seen.contains(call.id)) return;
        _seen.add(call.id);
        current.value = call;
      case 'call_signal':
        final sig = CallSignalEvent(
          callId: ev.data['callId']?.toString() ?? '',
          kind: ev.data['kind']?.toString() ?? '',
          from: ev.data['from']?.toString() ?? '',
          payload: ev.data['payload'] is Map
              ? Map<String, dynamic>.from(ev.data['payload'] as Map)
              : <String, dynamic>{},
        );
        if (sig.callId.isEmpty || sig.kind.isEmpty) return;
        final log = _backlog.putIfAbsent(sig.callId, () => []);
        log.add(sig);
        if (log.length > _backlogPerCall) {
          log.removeRange(0, log.length - _backlogPerCall);
        }
        while (_backlog.length > _backlogCallsMax) {
          _backlog.remove(_backlog.keys.first);
        }
        _signals.add(sig);
      case 'call_respond':
        final id = ev.data['id']?.toString() ?? '';
        final status = ev.data['status']?.toString() ?? '';
        // L'appelant a raccroché / l'appel est terminé : fermer la sonnerie.
        if ((status == 'ended' || status == 'declined' || status == 'missed') &&
            current.value?.id == id) {
          dismiss();
        }
        _responses.add(ev.data);
    }
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
    _signals.close();
    _responses.close();
    current.dispose();
  }
}
