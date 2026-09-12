import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ligne de saisie de texte : pression = légère réduction haptique+visuelle
/// (feedback immédiat, sans coût). Complément discret des boutons primaires.
class PressableField extends StatelessWidget {
  const PressableField({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => HapticFeedback.selectionClick(),
      child: child,
    );
  }
}
