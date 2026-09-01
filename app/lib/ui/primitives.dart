import 'package:flutter/material.dart';

import '../theme.dart';
import 'haptics.dart';
import 'motion.dart';

/// Pressable — pembungkus interaktif dengan scale-down halus saat ditekan.
/// Feedback visual instan (transform, bukan layout) — 120ms, interruptible.
class KitePressable extends StatefulWidget {
  const KitePressable({
    super.key,
    required this.onTap,
    this.onLongPress,
    required this.child,
    this.pressedScale = 0.97,
    this.haptic = true,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;

  /// Skala saat ditekan — sangat halus, tanpa bounce.
  final double pressedScale;

  /// Haptic ringan saat tap (bisa dimatikan per-instance).
  final bool haptic;

  @override
  State<KitePressable> createState() => _KitePressableState();
}

class _KitePressableState extends State<KitePressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: KiteMotion.fast,
    value: 1.0,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _ctrl.reverse();

  void _onTapUp(TapUpDetails _) => _ctrl.forward();

  void _onTapCancel() => _ctrl.forward();

  void _handleTap() {
    if (widget.haptic) KiteHaptics.light();
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      onLongPress: widget.onLongPress,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final t = CurvedAnimation(parent: _ctrl, curve: KiteMotion.easeOut).value;
          return Transform.scale(
            scale: 1.0 - (1.0 - t) * (1.0 - widget.pressedScale),
            child: Opacity(opacity: 0.85 + 0.15 * t, child: child),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// EmptyState — judul + penjelasan + aksi utama. Bukan sekadar "tidak ada item".
class KiteEmptyState extends StatelessWidget {
  const KiteEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: KiteColors.muted),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: KiteColors.fg,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              style: const TextStyle(color: KiteColors.muted, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add, size: 18),
                label: Text(actionLabel!),
                style: FilledButton.styleFrom(
                  backgroundColor: KiteColors.accent,
                  foregroundColor: KiteColors.accentInk,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ErrorState — apa yang terjadi + cara lanjut. Menyimpan data yang sudah diisi.
class KiteErrorState extends StatelessWidget {
  const KiteErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return KiteEmptyState(
      icon: Icons.cloud_off,
      title: 'Tidak bisa terhubung ke server',
      message: message,
      actionLabel: 'Coba lagi',
      onAction: onRetry,
    );
  }
}

/// SnackBar terpusat — aksi + undo opsional. Mengganti SnackBar tersebar di layar.
class KiteSnackBar {
  KiteSnackBar._();

  static void show(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    KiteHapticLevel haptic = KiteHapticLevel.none,
    Duration duration = const Duration(seconds: 3),
  }) {
    switch (haptic) {
      case KiteHapticLevel.success:
        KiteHaptics.success();
      case KiteHapticLevel.warning:
        KiteHaptics.warning();
      case KiteHapticLevel.error:
        KiteHaptics.error();
      case KiteHapticLevel.light:
        KiteHaptics.light();
      case KiteHapticLevel.none:
        break;
    }

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: KiteColors.fg)),
        backgroundColor: KiteColors.surface3,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: duration,
        action: (actionLabel != null && onAction != null)
            ? SnackBarAction(
                label: actionLabel,
                textColor: KiteColors.accent,
                onPressed: onAction,
              )
            : null,
      ),
    );
  }

  /// Konfirmasi aksi destruktif dengan UNDO — mengganti modal konfirmasi.
  static void showWithUndo(
    BuildContext context,
    String message,
    VoidCallback onUndo, {
    KiteHapticLevel haptic = KiteHapticLevel.none,
  }) {
    show(
      context,
      message,
      actionLabel: 'UNDO',
      onAction: onUndo,
      haptic: haptic,
      duration: const Duration(seconds: 5),
    );
  }
}

enum KiteHapticLevel { none, light, success, warning, error }
