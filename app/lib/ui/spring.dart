import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

/// Physique de ressort commune — dynamics naturels, jamais linéaires.
/// dampingRatio 0.8 : léger overshoot organique ; stiffness 380 : réactif
/// sans être nerveux.
final SpringDescription kKiteSpring = SpringDescription.withDampingRatio(
  mass: 1,
  ratio: 0.8,
  stiffness: 380,
);

final SpringDescription kKiteSpringSoft = SpringDescription.withDampingRatio(
  mass: 1,
  ratio: 0.95,
  stiffness: 260,
);

/// Simulation d'un spring 1D pilotée par un Ticker — pour les valeurs
/// dérivées (offsets de swipe, seuils) partagées entre widgets.
class SpringValue {
  SpringValue({this.value = 0, this.velocity = 0});

  double value;
  double velocity;
  Ticker? _ticker;
  SpringSimulation? _sim;
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback l) => _listeners.add(l);
  void removeListener(VoidCallback l) => _listeners.remove(l);

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Anime vers [target] avec le ressort [spring] (défaut : kKiteSpring).
  void animateTo(double target, {SpringDescription? spring}) {
    stop();
    _sim = SpringSimulation(spring ?? kKiteSpring, value, target, velocity);
    _ticker = Ticker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final sim = _sim;
    if (sim == null) return;
    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    velocity = sim.dx(t);
    value = sim.x(t);
    if (sim.isDone(t)) {
      velocity = 0;
      stop();
    }
    _notify();
  }

  /// Arrête l'animation en conservant la valeur courante.
  void stop() {
    _ticker?.dispose();
    _ticker = null;
    _sim = null;
  }

  void dispose() {
    stop();
    _listeners.clear();
  }

  /// Fixe instantanément (pas d'animation).
  void jumpTo(double v) {
    stop();
    value = v;
    velocity = 0;
    _notify();
  }
}

/// Scale élastique à l'appui : descente vers [pressedScale] en pressé,
/// retour avec rebond au relâchement.
class SpringScale extends StatefulWidget {
  const SpringScale({
    super.key,
    required this.child,
    this.pressedScale = 0.96,
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
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _a = Tween<double>(
    begin: 1,
    end: widget.pressedScale,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _c.forward(),
      onTapUp: (_) => _c.reverse(),
      onTapCancel: () => _c.reverse(),
      onTap: widget.onTap,
      child: ScaleTransition(scale: _a, child: widget.child),
    );
  }
}
