import 'package:flutter/animation.dart';

/// Token gerak (motion) terpusat — cf. brand-spec.md.
/// Durasi mengikuti standar micro-interaction:
///   fast   = 120ms (press, toggle kecil)
///   normal = 200ms (fade, slide konten)
///   slow   = 300ms (transisi layar / panel besar)
class KiteMotion {
  KiteMotion._();

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);

  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve easeInOut = Curves.easeInOutCubic;
  static const Curve spring = Curves.easeOutBack;
}
