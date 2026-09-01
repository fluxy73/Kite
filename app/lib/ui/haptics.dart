import 'package:flutter/services.dart';

/// Layanan haptic terpusat — feedback sensorial subtil, dibedakan per kategori.
/// Feedback visual harus selalu berfungsi tanpa getaran; haptic hanya pelengkap.
class KiteHaptics {
  KiteHaptics._();

  /// Global kill-switch (settings can turn haptics off).
  static bool enabled = true;

  /// Aksi ringan (tap chip, pilih filter) — sangat halus.
  static void light() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
  }

  /// Aksi penting berhasil (pesan terkirim, tersimpan).
  static void success() {
    if (!enabled) return;
    HapticFeedback.mediumImpact();
  }

  /// Peringatan (timeout, tidak ada jaringan).
  static void warning() {
    if (!enabled) return;
    HapticFeedback.heavyImpact();
  }

  /// Kesalahan (gagal kirim, error server).
  static void error() {
    if (!enabled) return;
    HapticFeedback.vibrate();
  }
}
