/// Heure courte « HH:MM » pour les métadonnées de messages — partagée par
/// la bulle et la feuille d'informations du message.
String kiteHhmm(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

/// Libellé de la durée des messages éphémères (0 = désactivés).
String kiteDisappearingLabel(int ms) {
  const dm24h = 24 * 3600 * 1000,
      dm7d = 7 * 24 * 3600 * 1000,
      dm90d = 90 * 24 * 3600 * 1000;
  switch (ms) {
    case dm24h:
      return '24 h';
    case dm7d:
      return '7 jours';
    case dm90d:
      return '90 jours';
    default:
      return 'désactivés';
  }
}
