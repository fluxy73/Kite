import 'package:flutter/material.dart';

import '../theme.dart';

/// KiteSkeleton — placeholder shimmer untuk pengganti spinner layar penuh.
/// Menjaga struktur layout tetap terlihat (perception of speed).
class KiteSkeleton extends StatefulWidget {
  const KiteSkeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<KiteSkeleton> createState() => _KiteSkeletonState();
}

class _KiteSkeletonState extends State<KiteSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + 2 * t, 0),
              end: Alignment(0 + 2 * t, 0),
              colors: const [
                KiteColors.surface,
                KiteColors.surface3,
                KiteColors.surface,
              ],
              stops: const [0.3, 0.5, 0.7],
            ),
          ),
        );
      },
    );
  }
}

/// Baris skeleton list-item (avatar + dua garis) — dipakai di list loading.
class KiteSkeletonRow extends StatelessWidget {
  const KiteSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          KiteSkeleton(width: 48, height: 48, radius: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KiteSkeleton(width: 140, height: 14),
                SizedBox(height: 8),
                KiteSkeleton(width: double.infinity, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton list penuh — pengganti spinner layar penuh saat load pertama.
class KiteSkeletonList extends StatelessWidget {
  const KiteSkeletonList({super.key, this.itemCount = 8});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < itemCount; i++) const KiteSkeletonRow(),
      ],
    );
  }
}
