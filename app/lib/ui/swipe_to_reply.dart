import 'package:flutter/material.dart';

import '../theme.dart';
import 'haptics.dart';
import 'spring.dart';

/// Swipe-to-reply : glissement horizontal avec rubber-band, haptic au
/// franchissement du seuil et retour élastique piloté par le ressort.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 56;

  // Retour élastique piloté par ressort (durée = settle de la simulation).
  late final AnimationController _snap = AnimationController(vsync: this);
  double _drag = 0;
  bool _fired = false;

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    setState(() {
      _drag = (_drag + d.delta.dx).clamp(0.0, _threshold + 28);
      // Rubber-band : résistance progressive au-delà du seuil.
      if (_drag > _threshold) {
        _drag = _threshold + (_drag - _threshold) * 0.35;
      }
      if (_drag >= _threshold && !_fired) {
        _fired = true;
        KiteHaptics.threshold();
      } else if (_drag < _threshold) {
        _fired = false;
      }
    });
  }

  void _onEnd(DragEndDetails d) {
    if (_fired) {
      widget.onReply();
      KiteHaptics.tap();
    }
    _fired = false;
    final from = _drag;
    void snapTick() {
      if (!mounted) {
        _snap.removeListener(snapTick);
        return;
      }
      // Simulation physique : le ressort relâché à [from] redescend vers
      // 0 ; on n'écrase pas la vitesse interne du contrôleur.
      setState(() {
        _drag = from * (1 - _snap.value);
      });
    }

    // Exactement un listener par retour élastique, retiré à la fin —
    // l'accumulation ferait courir N closures par frame après N swipes.
    _snap.addListener(snapTick);
    animateWithSpring(
      _snap,
      from: 0,
      to: 1,
      spring: kKiteSpringSoft,
    ).whenComplete(() {
      _snap.removeListener(snapTick);
      if (mounted) {
        setState(() => _drag = 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Opacity(
          opacity: (_drag / _threshold).clamp(0.0, 1.0),
          child: Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Icon(Icons.reply, size: 20, color: KiteColors.muted),
          ),
        ),
        Transform.translate(
          offset: Offset(_drag, 0),
          child: GestureDetector(
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: _onUpdate,
            onHorizontalDragEnd: _onEnd,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
