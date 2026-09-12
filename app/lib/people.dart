/// Noms courts des membres seed — une seule source de vérité, partagée par
/// les écrans conversation et appels.
const Map<String, String> kiteShortNames = {
  'u-lucas': 'Lucas',
  'u-emma': 'Emma',
  'u-thomas': 'Thomas',
  'u-sarah': 'Sarah',
};

/// Nom affiché pour un identifiant de membre ('Vous' pour soi-même).
String kiteDisplayName(String id, String meId) {
  if (id == meId) return 'Vous';
  return kiteShortNames[id] ?? id;
}

/// Initiales (2 lettres max) pour les avatars — remplace les copies
/// locales de ce calcul dans chaque écran.
String kiteInitials(String name) {
  final parts = name.split(' ').where((w) => w.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return parts.take(2).map((w) => w[0].toUpperCase()).join();
}
