import 'package:flutter/material.dart';

import 'spring.dart';

/// Entrée d'un message dans le flux : dérive verticale de ~12 dp combinée à
/// une montée d'opacité — **pilotée par le ressort** commun (damping 0.8,
/// stiffness 380 : léger overshoot organique), pas par une durée fixe.
/// Ne s'anime qu'au premier build de chaque bulle — l'état « déjà animé »
/// appartient à la liste (set d'ids) ; un enfant recyclé par
/// ListView.builder ne rejoue jamais son entrée au scroll-back.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({super.key, required this.child, this.animate = true});

  final Widget child;

  /// false : rend l'enfant tel quel (enfant recyclé déjà vu).
  final bool animate;

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  bool _started = false;

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<Offset> _drift = Tween<Offset>(
    begin: const Offset(0, 0.06), // ~12 dp sur une bulle de 200 dp
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _started = true;
      animateWithSpring(_c);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Jamais démarré (recréation d'un enfant déjà vu) : aucun layer
    // d'animation, l'enfant est rendu tel quel.
    if (!_started) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _drift, child: widget.child),
    );
  }
}
