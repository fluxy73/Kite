import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Physique de ressort commune — dynamics naturels, jamais linéaires.
/// dampingRatio 0.8 : léger overshoot organique ; stiffness 380 : réactif
/// sans être nerveux.
final SpringDescription kKiteSpring = SpringDescription.withDampingRatio(
  mass: 1,
  ratio: 0.8,
  stiffness: 380,
);

/// Retour au repos : amorti plus fort, sans overshoot (retour calme).
final SpringDescription kKiteSpringSoft = SpringDescription.withDampingRatio(
  mass: 1,
  ratio: 0.95,
  stiffness: 260,
);

/// Anime un contrôleur avec le ressort [spring] — durée pilotée par la
/// simulation physique (settle), pas par une durée fixe.
TickerFuture animateWithSpring(
  AnimationController c, {
  double from = 0,
  double to = 1,
  SpringDescription? spring,
}) {
  return c.animateWith(SpringSimulation(spring ?? kKiteSpring, from, to, 0));
}

/// Scale élastique à l'appui : descente ressort vers [pressedScale],
/// retour au repos sur kKiteSpringSoft (calme, sans rebond nerveux).
class SpringScale extends StatefulWidget {
  const SpringScale({
    super.key,
    required this.child,
    this.pressedScale = 0.94,
    this.onTap,
  });

  final Widget child;
  final double pressedScale;
  final VoidCallback? onTap;

  @override
  State<SpringScale> createState() => _SpringScaleState();
}

class _SpringScaleState extends State<SpringScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late final Animation<double> _a =
      Tween<double>(begin: 1, end: widget.pressedScale).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) =>
          animateWithSpring(_c, from: _c.value, to: 1, spring: kKiteSpring),
      onTapUp: (_) =>
          animateWithSpring(_c, from: _c.value, to: 0, spring: kKiteSpringSoft),
      onTapCancel: () =>
          animateWithSpring(_c, from: _c.value, to: 0, spring: kKiteSpringSoft),
      onTap: widget.onTap,
      child: ScaleTransition(scale: _a, child: widget.child),
    );
  }
}
