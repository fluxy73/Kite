import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Enregistrement et lecture réels des messages vocaux.
///
/// - Enregistrement : [record] en AAC (.m4a) dans le cache de l'app.
/// - Lecture : [just_audio] avec position/pause et flux de progression.
/// - Les chemins sont stockés dans `message.media['path']` ; le même widget
///   joue les fichiers locaux (offline) et distants (mode serveur).
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  String? _path;

  /// true si un micro est disponible (desktop sans micro -> bouton masqué).
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// Démarre l'enregistrement ; retourne false si le micro est refusé.
  Future<bool> start() async {
    try {
      final dir = await getTemporaryDirectory();
      _path =
          '${dir.path}${Platform.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _path!,
      );
      return true;
    } catch (_) {
      _path = null;
      return false;
    }
  }

  /// Arrête l'enregistrement et renvoie (chemin, durée en secondes),
  /// ou null si rien n'a été enregistré / fichier vide ou minuscule.
  Future<(String, int)?> stop() async {
    final path = _path;
    _path = null;
    try {
      final stopped = await _recorder.stop();
      final p = stopped ?? path;
      if (p == null) return null;
      final f = File(p);
      if (!f.existsSync() || f.lengthSync() < 512) {
        try {
          f.deleteSync();
        } catch (_) {}
        return null;
      }
      final dur = DateTime.now().millisecondsSinceEpoch - _startMs;
      return (p, dur < 1000 ? 1 : dur ~/ 1000);
    } catch (_) {
      return null;
    }
  }

  int _startMs = 0;

  /// [start] en mémorisant l'horodatage (durée réelle mesurée à l'arrêt).
  Future<bool> startWithStamp() async {
    _startMs = DateTime.now().millisecondsSinceEpoch;
    return start();
  }

  void dispose() => _recorder.dispose();
}
