import 'package:flutter/material.dart';

/// Entrée d'un message dans le flux : dérive verticale de 12 dp combinée à
/// une montée d'opacité en 200 ms (courbe douce, jamais brutale).
/// Ne s'anime qu'au premier build de chaque bulle — les rebuilds (réactions,
/// traduction, timers) ne rejouent pas l'effet.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({super.key, required this.child});

  final Widget child;

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 0,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _drift = Tween<Offset>(
    begin: const Offset(0, 0.06), // ~12 dp sur une bulle de 200 dp
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _drift, child: widget.child),
    );
  }
}
