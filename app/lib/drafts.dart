import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Brouillons de messages, persistés localement (un JSON par app).
/// Chemin identique à [LocalStore] : dossier de données par plateforme.
class DraftStore {
  DraftStore._();
  static final DraftStore instance = DraftStore._();

  static const _ttl = Duration(days: 30);
  final Map<String, String> _cache = {};
  File? _file;
  bool _loaded = false;
  bool _dirty = false;

  File? get _storeFile {
    if (_file != null) return _file;
    try {
      final env = Platform.environment;
      String base;
      if (Platform.isWindows) {
        base = env['APPDATA'] ?? env['HOME'] ?? Directory.current.path;
      } else if (Platform.isMacOS) {
        base = '${env['HOME'] ?? Directory.current.path}/Library/Application Support';
      } else {
        base = env['HOME'] ?? Directory.current.path;
      }
      final dir = Directory('$base/kite');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _file = File('${dir.path}${Platform.pathSeparator}kite-drafts.json');
    } catch (_) {
      return null; // persistance indisponible : cache mémoire seul
    }
    return _file;
  }

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final f = _storeFile;
    if (f == null || !f.existsSync()) return;
    try {
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final e in raw.entries) {
        final v = e.value as Map<String, dynamic>?;
        if (v == null) continue;
        final ts = v['ts'] as int? ?? 0;
        if (now - ts > _ttl.inMilliseconds) continue; // brouillon périmé
        _cache[e.key] = v['text'] as String? ?? '';
      }
    } catch (_) {
      // fichier corrompu : on repart de zéro
    }
  }

  void _flush() {
    final f = _storeFile;
    if (f == null) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      f.writeAsStringSync(jsonEncode(
        _cache.map((k, v) => MapEntry(k, {'text': v, 'ts': now})),
      ));
      _dirty = false;
    } catch (_) {}
  }

  /// Brouillon d'une conversation (peut être vide).
  String load(String chatId) {
    _ensureLoaded();
    return _cache[chatId] ?? '';
  }

  /// Sauvegarde (debounce 500 ms via [scheduleSave] pour la saisie fréquent).
  void save(String chatId, String text) {
    _ensureLoaded();
    if (text.isEmpty) {
      _cache.remove(chatId);
    } else {
      _cache[chatId] = text;
    }
    _dirty = true;
  }

  /// Efface le brouillon (après envoi).
  void clear(String chatId) {
    _ensureLoaded();
    _cache.remove(chatId);
    _flush();
  }

  /// Écriture différée : à appeler périodiquement (ou à la sortie d'écran).
  void flushIfNeeded() {
    if (_dirty) _flush();
  }

  /// Test uniquement : réinitialise et force la relecture au prochain accès.
  @visibleForTesting
  void resetForTest({File? file}) {
    _cache.clear();
    _file = file;
    _loaded = false;
    _dirty = false;
  }
}
