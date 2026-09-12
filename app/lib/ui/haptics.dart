import 'package:flutter/services.dart';

/// Haptique tactile — retours mécaniques discrets synchronisés aux actions :
/// envoi, démarrage d'enregistrement, réaction, seuils de swipe.
class KiteHaptics {
  KiteHaptics._();

  /// Appui léger (boutons secondaires, sélection).
  static void tap() => HapticFeedback.selectionClick();

  /// Envoi d'un message / vocal : toc ferme et rassurant.
  static void send() => HapticFeedback.mediumImpact();

  /// Début d'enregistrement : double toc d'engagement.
  static void recordStart() {
    HapticFeedback.lightImpact();
    Future.delayed(const Duration(milliseconds: 90), () {
      HapticFeedback.lightImpact();
    });
  }

  /// Réaction emoji : petit tic de sélection.
  static void reactTick() => HapticFeedback.selectionClick();

  /// Franchissement du seuil de swipe-to-reply : toc moyen unique.
  static void threshold() => HapticFeedback.mediumImpact();
}
