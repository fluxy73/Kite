import 'package:flutter/material.dart';

import '../theme.dart';

/// Petit avatar à initiales (36dp, 64dp en large) — partagé par
/// conversation et infos conversation.
class KiteAvatar extends StatelessWidget {
  const KiteAvatar(
      {super.key, required this.name, required this.group, this.large = false});

  final String name;
  final bool group;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final size = large ? 64.0 : 36.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: KiteColors.surface2,
        borderRadius: BorderRadius.circular(group ? size * 0.33 : size / 2),
        border: Border.all(color: KiteColors.border),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style:
            TextStyle(fontWeight: FontWeight.w600, fontSize: large ? 22 : 13),
      ),
    );
  }
}
