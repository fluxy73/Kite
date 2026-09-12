import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'voice.dart';

/// Lecture d'un vocal : fichier réel via just_audio (position, pause,
/// vitesse, scrub) ou timeline simulée en repli (seed / fichier absent).
class VoicePlayer {
  final ValueNotifier<double> progress = ValueNotifier(0);
  final ValueNotifier<bool> playing = ValueNotifier(false);
  Timer? _t;
  int _total = 0;
  int _elapsed = 0;
  final AudioPlayer _audio = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  String? _loadedPath;

  bool get isPlaying => playing.value;

  void play({required int durationSec, String? path}) {
    _total = durationSec;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      _playFile(path);
      return;
    }
    // Fallback : timeline simulée (seed / vocal sans fichier).
    _elapsed = 0;
    playing.value = true;
    progress.value = 0;
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed++;
      if (_elapsed >= _total * 5) {
        pause();
        return;
      }
      progress.value = _elapsed / (_total * 5);
    });
  }

  Future<void> _playFile(String path) async {
    try {
      if (_loadedPath != path) {
        await _audio.setFilePath(path);
        _loadedPath = path;
      }
      _posSub?.cancel();
      _posSub = _audio.positionStream.listen((p) {
        final d = _audio.duration;
        if (d != null && d.inMilliseconds > 0) {
          progress.value = p.inMilliseconds / d.inMilliseconds;
        }
      });
      _audio.playerStateStream.listen((s) {
        playing.value = s.playing;
        if (s.processingState == ProcessingState.completed) {
          playing.value = false;
          progress.value = 0;
          _audio.seek(Duration.zero);
          _audio.pause();
        }
      });
      await _audio.play();
    } catch (_) {
      // Fichier illisible/effacé : repli timeline.
      playing.value = false;
      play(durationSec: _total);
    }
  }

  /// Reprend la lecture là où elle en est (après pause/scrub) : fichier
  /// réel → just_audio joue depuis la position seekée ; repli timeline
  /// simulée uniquement si aucun fichier lisible.
  Future<void> resume() async {
    if (_loadedPath != null) {
      await _audio.play();
      return;
    }
    playing.value = true;
    _t?.cancel();
    _t = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _elapsed++;
      if (_elapsed >= _total * 5) {
        pause();
        return;
      }
      progress.value = _elapsed / (_total * 5);
    });
  }

  void pause() {
    _t?.cancel();
    if (_loadedPath != null) {
      _audio.pause();
    } else {
      playing.value = false;
    }
  }

  Future<void> setSpeed(double s) => _audio.setSpeed(s);

  /// Positionne la lecture à [fraction] (0..1) de la durée totale —
  /// scrubbing sur la waveform (fichier réel) ou timeline simulée.
  Future<void> seekTo(double fraction) async {
    final f = fraction.clamp(0.0, 1.0);
    if (_loadedPath != null) {
      final d = _audio.duration;
      if (d != null) {
        await _audio.seek(d * f);
      }
    } else {
      _elapsed = (f * _total * 5).round();
      progress.value = f;
    }
  }

  /// Stoppe tout (utilisé à la fermeture de la pré-écoute).
  Future<void> hardStop() async {
    _t?.cancel();
    _posSub?.cancel();
    try {
      await _audio.stop();
    } catch (_) {}
    playing.value = false;
  }

  void dispose() {
    _t?.cancel();
    _posSub?.cancel();
    _audio.dispose();
    progress.dispose();
    playing.dispose();
  }
}

/// État d'enregistrement vocal : historique d'amplitudes (barres de la
/// waveform), amplitude instantanée, secondes écoulées — possède le flux
/// du micro et le timer ; l'écran n'écoute que [changes].
class VoiceRecording {
  VoiceRecording(this.recorder);

  final VoiceRecorder recorder;
  static const int barCount = 34;

  final ValueNotifier<List<double>> bars =
      ValueNotifier<List<double>>(List.filled(barCount, 0.0));
  final ValueNotifier<double> liveAmp = ValueNotifier(0);
  final ValueNotifier<int> seconds = ValueNotifier(0);
  final ValueNotifier<bool> active = ValueNotifier(false);

  Timer? _timer;
  StreamSubscription<dynamic>? _ampSub;

  void start() {
    _timer?.cancel();
    _ampSub?.cancel();
    active.value = true;
    seconds.value = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      seconds.value++;
    });
    // Waveform vivante : amplitudes réelles du micro (20 mesures/seconde,
    // barres glissantes).
    _ampSub = recorder.onAmplitudeChanged(const Duration(milliseconds: 50)).listen(
      (a) {
        final norm = ((a.current + 50) / 50).clamp(0.0, 1.0);
        final next = List.of(bars.value)..removeAt(0)..add(norm);
        bars.value = next;
        liveAmp.value = norm;
      },
      onError: (_) {},
    );
  }

  List<double> snapshotBars() => List.of(bars.value);

  void stop() {
    _timer?.cancel();
    _ampSub?.cancel();
    _ampSub = null;
    active.value = false;
  }

  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    bars.dispose();
    liveAmp.dispose();
    seconds.dispose();
    active.dispose();
  }
}
