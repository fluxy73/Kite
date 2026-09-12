import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../call_center.dart';
import '../call_engine.dart';
import '../theme.dart';
import 'calls_screen.dart';

/// Écran plein écran d'appel entrant qui sonne, avec accepter / refuser.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.api,
    required this.call,
    this.onAccepted,
  });

  final KiteApi api;
  final IncomingCall call;
  final VoidCallback? onAccepted;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ring;
  Timer? _vibration;
  Timer? _countdown;
  int _remaining = 30;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat(reverse: true);
    // Pulsation périodique pendant la sonnerie.
    _vibration = Timer.periodic(const Duration(milliseconds: 550), (_) {
      if (mounted) setState(() {});
    });
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_ending) return;
      setState(() => _remaining -= 1);
      if (_remaining <= 0) _timeout();
    });
  }

  @override
  void dispose() {
    _ring.dispose();
    _vibration?.cancel();
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _accept() async {
    _countdown?.cancel();
    final call = widget.call;
    await widget.api.respondCall(call.id, 'accepted').catchError((_) => null);
    CallCenter.instance.dismiss();
    if (!mounted) return;
    widget.onAccepted?.call();
    // Appel 1:1 temps réel (mode serveur) : moteur WebRTC côté appelé —
    // il répondra à l'offer de l'appelant via la signalisation relayée.
    if (widget.api.baseUrl.isNotEmpty && !call.group) {
      final engine = CallEngine(api: widget.api, callId: call.id);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => InCallScreen(
            name: call.callerName,
            video: call.isVideo,
            memberNames: const [],
            engine: engine,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          name: call.callerName,
          video: call.isVideo,
          memberNames: const [],
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _decline() async {
    _countdown?.cancel();
    await widget.api.respondCall(widget.call.id, 'declined').catchError((_) => null);
    CallCenter.instance.dismiss();
    if (mounted) Navigator.of(context).pop();
  }

  /// Expire la sonnerie après 30 s : marque l'appel manqué côté serveur.
  Future<void> _timeout() async {
    if (_ending) return;
    _ending = true;
    _ring.stop();
    _countdown?.cancel();
    _vibration?.cancel();
    final call = widget.call;
    await widget.api.respondCall(call.id, 'missed').catchError((_) => null);
    CallCenter.instance.notifyMissed();
    CallCenter.instance.dismiss();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Appel manqué — sans réponse')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final initials = call.callerName
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Scaffold(
      backgroundColor: KiteColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Anneau pulsant autour de l'avatar.
            ScaleTransition(
              scale: Tween(begin: 0.9, end: 1.15).animate(
                CurvedAnimation(parent: _ring, curve: Curves.easeInOut),
              ),
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: KiteColors.accent.withValues(alpha: 0.6),
                    width: 3,
                  ),
                ),
                child: Center(
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: KiteColors.surface2,
                      shape: BoxShape.circle,
                      border: Border.all(color: KiteColors.border),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      initials,
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    value: _remaining / 30,
                    strokeWidth: 4,
                    color: KiteColors.tint2,
                    backgroundColor: KiteColors.surface2,
                  ),
                ),
                Text('$_remaining',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            Text(_remaining <= 1 ? 'Sonnerie...' : 'Sans réponse dans $_remaining s',
                style: const TextStyle(color: KiteColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(call.callerName,
                style: const TextStyle(
                  fontSize: 24,
                  fontFamilyFallback: kDisplayFont,
                  fontWeight: FontWeight.w500,
                )),
            const SizedBox(height: 8),
            Text(
              call.isVideo ? 'Appel vidéo entrant…' : 'Appel entrant…',
              style: const TextStyle(color: KiteColors.muted, fontSize: 15),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ActionButton(
                  icon: Icons.call,
                  label: 'Accepter',
                  color: KiteColors.tint2,
                  onTap: _accept,
                ),
                _ActionButton(
                  icon: Icons.call_end,
                  label: 'Refuser',
                  color: KiteColors.danger,
                  onTap: _decline,
                ),
              ],
            ),
            const SizedBox(height: 30),
            const Text('🔒 Chiffré de bout en bout',
                style: TextStyle(color: KiteColors.muted, fontSize: 11)),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, size: 28, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(color: KiteColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
