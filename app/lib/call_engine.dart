import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'call_center.dart';

/// Moteur WebRTC d'un appel 1:1 : média local, peer connection, signalisation
/// (offer/answer/ICE relayés par le serveur) et état exposé à l'écran.
///
/// Flow appelant : getUserMedia -> offer -> [serveur] -> answer -> ICE.
/// Flow appelé   : getUserMedia -> reçoit l'offer -> answer -> ICE.
class CallEngine {
  CallEngine({required this.api, required this.callId});

  /// L'API doit être un [KiteApi] (signalisation serveur). Hors-ligne,
  /// [available] reste false et l'écran garde son rendu simulé.
  final dynamic api;
  final String callId;

  static const _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  StreamSubscription<CallSignalEvent>? _sigSub;
  StreamSubscription<Map<String, dynamic>>? _respSub;
  bool _hasRemoteDesc = false;
  bool _isCaller = false;
  bool _offerSent = false;
  final List<RTCIceCandidate> _pendingIce = [];
  Timer? _connectTimeout;
  bool _disposed = false;

  /// true si la signalisation serveur est disponible (mode connecté).
  bool get available => api is KiteApi && callId.isNotEmpty;

  /// Flux locaux (caméra + micro) et distants, observés par l'écran.
  final ValueNotifier<MediaStream?> localStream = ValueNotifier<MediaStream?>(null);
  final ValueNotifier<MediaStream?> remoteStream = ValueNotifier<MediaStream?>(null);

  /// idle -> connecting -> connected | failed
  final ValueNotifier<String> state = ValueNotifier<String>('idle');

  /// Démarre en tant qu'appelant : média prêt, offre envoyée dès que l'appelé
  /// a répondu « accepted » (son moteur n'existe qu'à partir de là).
  Future<void> startAsCaller({bool video = false}) async {
    if (!available) return;
    _isCaller = true;
    state.value = 'connecting';
    // Sonnerie : si personne ne décroche, l'appel passe en échec.
    _armConnectTimeout(const Duration(seconds: 45));
    await _setup(media: video ? 'video' : 'audio');
  }

  /// Démarre en tant qu'appelé : média prêt, puis réponse à l'offer reçue
  /// (rejouée depuis le backlog de [CallCenter] si elle est déjà arrivée).
  Future<void> startAsCallee({bool video = false}) async {
    if (!available) return;
    state.value = 'connecting';
    await _setup(media: video ? 'video' : 'audio');
    for (final sig in CallCenter.instance.signalBacklog(callId)) {
      _onSignal(sig);
    }
  }

  Future<void> _setup({required String media}) async {
    MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        if (media == 'video') 'video': {'facingMode': 'user', 'width': 1280, 'height': 720},
      });
    } catch (_) {
      // Micro/caméra refusés ou indisponibles : pas d'appel possible.
      state.value = 'failed';
      return;
    }
    _localStream = stream;
    localStream.value = stream;

    final pc = await createPeerConnection({'iceServers': _iceServers});
    _pc = pc;
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        remoteStream.value = _remoteStream;
      }
    };
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _send('ice', candidate.toMap());
    };
    pc.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _connectTimeout?.cancel();
          state.value = 'connected';
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          state.value = 'failed';
        default:
          break;
      }
    };

    // Signaux WebRTC entrants + réponses d'appel (decroche / raccroche).
    _sigSub = CallCenter.instance.signals
        .where((s) => s.callId == callId)
        .listen(_onSignal);
    _respSub = CallCenter.instance.responses.listen((r) {
      final id = r['id']?.toString();
      final status = r['status']?.toString();
      if (id != callId) return;
      if (_isCaller && status == 'accepted' && !_offerSent) {
        _createAndSendOffer(); // l'appelé décroche : envoi de l'offre
      }
      if (status == 'ended' || status == 'declined' || status == 'missed') {
        state.value = 'ended';
        // Libère média/connexions sans réinitialiser l'état : l'écran doit
        // encore lire 'ended' pour afficher « Appel terminé » et sortir.
        _disposeMediaOnly();
      }
    });
  }

  Future<void> _createAndSendOffer() async {
    final pc = _pc;
    if (pc == null || _offerSent) return;
    _offerSent = true;
    final offer = await pc.createOffer({'offerToReceiveVideo': true, 'offerToReceiveAudio': true});
    await pc.setLocalDescription(offer);
    await _send('offer', offer.toMap());
    _armConnectTimeout(const Duration(seconds: 20));
  }

  void _onSignal(CallSignalEvent sig) {
    if (_disposed) return;
    switch (sig.kind) {
      case 'offer':
        _onOffer(sig.payload);
      case 'answer':
        _onAnswer(sig.payload);
      case 'ice':
        _onIce(sig.payload);
    }
  }

  Future<void> _onOffer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null || _hasRemoteDesc) return;
    await pc.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String, payload['type'] as String? ?? 'offer'));
    _hasRemoteDesc = true;
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await _send('answer', answer.toMap());
    await _flushPendingIce();
    _armConnectTimeout(const Duration(seconds: 20));
  }

  Future<void> _onAnswer(Map<String, dynamic> payload) async {
    final pc = _pc;
    if (pc == null || _hasRemoteDesc) return;
    await pc.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String, payload['type'] as String? ?? 'answer'));
    _hasRemoteDesc = true;
    await _flushPendingIce();
  }

  Future<void> _onIce(Map<String, dynamic> payload) async {
    final candidate = RTCIceCandidate(
      payload['candidate'] as String?,
      payload['sdpMid'] as String?,
      (payload['sdpMLineIndex'] as num?)?.toInt(),
    );
    final pc = _pc;
    if (pc == null) return;
    if (!_hasRemoteDesc) {
      _pendingIce.add(candidate); // ICE avant la description distante : buffer
      return;
    }
    await pc.addCandidate(candidate);
  }

  Future<void> _flushPendingIce() async {
    final pc = _pc;
    if (pc == null) return;
    for (final c in _pendingIce) {
      await pc.addCandidate(c);
    }
    _pendingIce.clear();
  }

  void _armConnectTimeout([Duration duration = const Duration(seconds: 20)]) {
    _connectTimeout?.cancel();
    _connectTimeout = Timer(duration, () {
      if (!_disposed && state.value != 'connected') {
        state.value = 'failed';
      }
    });
  }

  Future<void> _send(String kind, Map<String, dynamic> payload) async {
    try {
      await (api as KiteApi).sendCallSignal(callId, kind, payload);
    } catch (_) {
      // Signalisation momentanément indisponible : le timeout de connexion
      // fera passer l'appel en 'failed' si les signaux ne passent pas.
    }
  }

  // ---------- Contrôles ----------

  void setMicMuted(bool muted) {
    for (final t in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
  }

  void setCameraEnabled(bool enabled) {
    for (final t in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  void switchCamera() {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) {
      Helper.switchCamera(track);
    }
  }

  /// Raccroche : notifie le serveur (ended) et libère les ressources.
  Future<void> hangUp() async {
    try {
      await (api as KiteApi?)?.respondCall(callId, 'ended');
    } catch (_) {}
    dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connectTimeout?.cancel();
    _sigSub?.cancel();
    _respSub?.cancel();
    _pc?.close();
    _pc = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _remoteStream = null;
    localStream.value = null;
    remoteStream.value = null;
    state.value = 'idle';
  }

  /// Libère les ressources média/connexions sans remettre l'état à zéro —
  /// utilisé quand l'écran doit encore lire l'état final (ex. 'failed').
  void _disposeMediaOnly() {
    _connectTimeout?.cancel();
    _sigSub?.cancel();
    _sigSub = null;
    _respSub?.cancel();
    _respSub = null;
    _pc?.close();
    _pc = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    _remoteStream = null;
    localStream.value = null;
    remoteStream.value = null;
  }
}
