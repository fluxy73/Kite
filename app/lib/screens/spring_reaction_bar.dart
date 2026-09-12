import 'package:flutter/material.dart';

import '../ui/ui.dart';

/// Barre de réactions flottante : les emojis apparaissent avec un rebond
/// de ressort (cascade douce).
class SpringReactionBar extends StatelessWidget {
  const SpringReactionBar({super.key, required this.onPick});

  final void Function(String emoji) onPick;

  static const _emojis = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < _emojis.length; i++)
          _SpringEmoji(
            emoji: _emojis[i],
            delay: i * 40,
            onTap: () => onPick(_emojis[i]),
          ),
      ],
    );
  }
}

class _SpringEmoji extends StatefulWidget {
  const _SpringEmoji({
    required this.emoji,
    required this.delay,
    required this.onTap,
  });

  final String emoji;
  final int delay;
  final VoidCallback onTap;

  @override
  State<_SpringEmoji> createState() => _SpringEmojiState();
}

class _SpringEmojiState extends State<_SpringEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late final Animation<double> _scale = Tween<double>(
    begin: 0.0,
    end: 1.0,
  ).animate(_c);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) animateWithSpring(_c);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        KiteHaptics.reactTick();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: ScaleTransition(
          scale: _scale,
          child: Text(widget.emoji, style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }
}
