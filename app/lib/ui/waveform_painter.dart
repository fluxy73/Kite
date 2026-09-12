import 'package:flutter/material.dart';

/// Waveform organique : barres arrondies à hauteur d'amplitude, portion
/// jouée en pleine couleur, à venir en atténué.
class KiteWaveformPainter extends CustomPainter {
  KiteWaveformPainter({
    required this.bars,
    required this.progress,
    required this.playedColor,
    required this.pendingColor,
  });

  final List<double> bars;
  final double progress;
  final Color playedColor;
  final Color pendingColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const gap = 2.0;
    final barW = size.width / bars.length - gap;
    final mid = size.height / 2;
    final playedUpTo = size.width * progress.clamp(0.0, 1.0);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final x = i * (barW + gap) + barW / 2;
      final h = (6.0 + bars[i] * (size.height - 6))
          .clamp(4.0, size.height)
          .toDouble();
      paint.color = x <= playedUpTo ? playedColor : pendingColor;
      paint.strokeWidth = barW.clamp(1.5, 4.0);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(KiteWaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.playedColor != playedColor;
}
