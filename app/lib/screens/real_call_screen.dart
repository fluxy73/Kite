import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../call_center.dart';
import '../call_engine.dart';
import '../theme.dart';
import 'calls_screen.dart';

/// Écran de l'appelant pour un appel 1:1 temps réel : initie l'appel, sonne,
/// puis bascule sur [InCallScreen] (moteur WebRTC) quand l'appelé décroche.
/// Hors-ligne (serveur injoignable) : bascule sur l'appel simulé existant.
class RealCallScreen extends StatefulWidget {
  const RealCallScreen({
    super.key,
    required this.api,
    required this.chatId,
    required this.name,
    this.video = false,
  });

  final KiteApi api;
  final String chatId;
  final String name;
  final bool video;

  @override
  State<RealCallScreen> createState() => _RealCallScreenState();
}

class _RealCallScreenState extends State<RealCallScreen> {
  Map<String, dynamic>? _call;
  Timer? _timeout;
  StreamSubscription<Map<String, dynamic>>? _respSub;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _initiate();
  }

  Future<void> _initiate() async {
    try {
      final call = await widget.api.initiateCall(widget.chatId, kind: widget.video ? 'video' : 'audio');
      if (!mounted) return;
      // Mode hors-ligne : l'API locale renvoie un appel simulé — l'écran
      // d'appel simulé existant prend le relais immédiatement.
      if (call['simulated'] == true) {
        _replace(InCallScreen(name: widget.name, video: widget.video));
        return;
      }
      setState(() => _call = call);
      _timeout = Timer(const Duration(seconds: 30), _onNoAnswer);
      _respSub = CallCenter.instance.responses.listen(_onResponse);
    } catch (_) {
      // Pas de serveur : l'appel simulé existant prend le relais.
      _replace(InCallScreen(name: widget.name, video: widget.video));
    }
  }

  void _onResponse(Map<String, dynamic> r) {
    if (_done || r['id']?.toString() != _call?['id']?.toString()) return;
    switch (r['status']?.toString()) {
      case 'accepted':
        // L'appelé décroche : le moteur WebRTC démarre, l'écran d'appel réel
        // prend le relais (il devient propriétaire du moteur).
        _done = true;
        _timeout?.cancel();
        _respSub?.cancel();
        final engine = CallEngine(api: widget.api, callId: _call!['id'] as String);
        _replace(InCallScreen(
          name: widget.name,
          video: widget.video,
          engine: engine,
          isCaller: true,
        ));
      case 'declined':
        _finish('Appel refusé');
      case 'missed':
        _finish('Sans réponse');
    }
  }

  void _onNoAnswer() {
    if (_done || !mounted) return;
    final callId = _call?['id']?.toString();
    if (callId != null) {
      widget.api.respondCall(callId, 'ended').catchError((_) => null);
    }
    _finish('Sans réponse');
  }

  void _finish(String message) {
    if (_done) return;
    _done = true;
    _timeout?.cancel();
    _respSub?.cancel();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop();
  }

  /// Remplace cet écran de sonnerie par l'écran donné.
  void _replace(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => screen, fullscreenDialog: true),
    );
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _respSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KiteColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Text(widget.name,
                style: const TextStyle(fontSize: 24, fontFamilyFallback: kDisplayFont, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text(
              widget.video ? 'Appel vidéo…' : 'Appel audio…',
              style: const TextStyle(color: KiteColors.muted, fontSize: 15),
            ),
            const SizedBox(height: 18),
            const Text('Sonnerie…',
                style: TextStyle(color: KiteColors.accent, fontSize: 14)),
            const Spacer(),
            InkWell(
              onTap: () {
                final callId = _call?['id']?.toString();
                if (callId != null) {
                  widget.api.respondCall(callId, 'ended').catchError((_) => null);
                }
                Navigator.of(context).pop();
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(color: KiteColors.danger, shape: BoxShape.circle),
                child: const Icon(Icons.call_end, size: 26, color: Colors.white),
              ),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
