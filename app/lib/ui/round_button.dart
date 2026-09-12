import 'package:flutter/material.dart';

import '../theme.dart';
import 'spring.dart';

/// Bouton rond du design system : pressage = ressort (scale-down, retour
/// calme), fond accent ou transparent.
class KiteRoundBtn extends StatelessWidget {
  const KiteRoundBtn({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return SpringScale(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent ? KiteColors.accent : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 21,
            color: accent ? KiteColors.accentInk : KiteColors.muted,
          ),
        ),
      ),
    );
  }
}
