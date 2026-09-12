import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui/haptics.dart';
import '../ui/round_button.dart';
import '../ui/waveform_painter.dart';
import '../voice_player.dart';

/// Pré-écoute d'un vocal avant envoi : lecture/pause, scrub sur la waveform
/// (amplitudes captées pendant l'enregistrement), vitesse, abandon.
/// Retourne true pour envoyer (pop(true)), false pour abandonner.
Future<bool> showVoiceReviewSheet(
  BuildContext context, {
  required VoicePlayer player,
  required List<double> bars,
  required int durationSec,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: KiteColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: _VoiceReviewSheet(
          player: player, bars: bars, durationSec: durationSec),
    ),
  ).then((v) => v ?? false);
}

class _VoiceReviewSheet extends StatefulWidget {
  const _VoiceReviewSheet({
    required this.player,
    required this.bars,
    required this.durationSec,
  });

  final VoicePlayer player;
  final List<double> bars;
  final int durationSec;

  @override
  State<_VoiceReviewSheet> createState() => _VoiceReviewSheetState();
}

class _VoiceReviewSheetState extends State<_VoiceReviewSheet> {
  double _speed = 1.0;
  double _scrub = 0;

  @override
  void initState() {
    super.initState();
    widget.player.progress.addListener(_onProgress);
  }

  void _onProgress() {
    if (mounted) setState(() => _scrub = widget.player.progress.value);
  }

  @override
  void dispose() {
    widget.player.progress.removeListener(_onProgress);
    super.dispose();
  }

  String get _time {
    final total = widget.durationSec;
    final pos = (total * _scrub).round();
    final p =
        '${(pos ~/ 60).toString().padLeft(2, '0')}:${(pos % 60).toString().padLeft(2, '0')}';
    final t =
        '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
    return '$p / $t';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 18, color: KiteColors.accent),
              const SizedBox(width: 8),
              const Text(
                'Écouter avant d’envoyer',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(_time,
                  style: TextStyle(
                      color: KiteColors.muted,
                      fontSize: 12,
                      fontFamilyFallback: const ['monospace'])),
            ],
          ),
          const SizedBox(height: 14),
          // Waveform scrubbable (les vraies amplitudes captées).
          GestureDetector(
            onHorizontalDragUpdate: (d) async {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final f = (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
              await player.seekTo(f);
            },
            onHorizontalDragEnd: (_) {
              if (!player.playing.value) {
                player.resume();
              }
            },
            child: SizedBox(
              height: 44,
              child: CustomPaint(
                painter: KiteWaveformPainter(
                  bars: widget.bars,
                  progress: _scrub,
                  playedColor: KiteColors.accent,
                  pendingColor: KiteColors.accent.withValues(alpha: 0.32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Pause / reprise.
              ValueListenableBuilder<bool>(
                valueListenable: player.playing,
                builder: (_, playing, __) => KiteRoundBtn(
                  icon: playing ? Icons.pause : Icons.play_arrow,
                  tooltip: playing ? 'Pause' : 'Reprendre',
                  accent: true,
                  onTap: () {
                    if (playing) {
                      player.pause();
                    } else {
                      player.resume();
                    }
                  },
                ),
              ),
              const SizedBox(width: 18),
              // Vitesse cyclée 1x → 1,5x → 2x.
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () async {
                  KiteHaptics.tap();
                  final next =
                      _speed == 1.0 ? 1.5 : (_speed == 1.5 ? 2.0 : 1.0);
                  setState(() => _speed = next);
                  await player.setSpeed(next);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: KiteColors.surface2,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: KiteColors.border),
                  ),
                  child: Text(
                    '${_speed}x',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KiteColors.ephemeral,
                    side: BorderSide(
                        color: KiteColors.ephemeral.withValues(alpha: 0.5)),
                  ),
                  onPressed: () => Navigator.pop(context, false),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Abandonner'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: KiteColors.accent,
                    foregroundColor: KiteColors.accentInk,
                  ),
                  onPressed: () {
                    KiteHaptics.send();
                    Navigator.pop(context, true);
                  },
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Envoyer'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
