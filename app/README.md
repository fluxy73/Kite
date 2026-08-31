# Kite App (Flutter)

Client Flutter de la messagerie Kite, branché sur le serveur Go (`server/`).
Cible : **Android, iOS, Windows, Linux** (et macOS). Thème reprenant les tokens
de `brand-spec.md` (fond `#0a0a0c`, accent ambre `#d9985f`, serif display).

## Première installation

```bash
# 1. Depuis le dossier app/ :
flutter create . --platforms=android,ios,windows,linux
#    (génère les dossiers de plateforme ; ne touche pas à lib/ ni pubspec.yaml)

# 2. Dépendances + lancement
flutter pub get
flutter run -d windows      # ou -d linux, -d <device android>
```

Le serveur doit tourner pendant l'app (voir `server/README.md`) :
```bash
cd server && go run .       # écoute sur :8080
```

### URL du serveur
- Desktop (Windows/Linux/macOS) : `http://localhost:8080` (défaut).
- Émulateur Android : `flutter run --dart-define=KITE_API=http://10.0.2.2:8080`

## Ce qui est implémenté

- **Liste des discussions** : chargée depuis l'API, filtres (Toutes / Non lues /
  Groupes), appui long (épingler, sourdine, archiver, supprimer), pull-to-refresh,
  états vide / erreur avec « Réessayer ».
- **Conversation temps réel** (WebSocket, repli SSE automatique) :
  - types de messages : texte, photo, vidéo, GIF, note vidéo, vocal (lecteur
    simulé 1×), document, sondage (vote réel via API), événement (RSVP local),
    contact, localisation, appel manqué, message système ;
  - appui long sur un message : réactions rapides (❤️ 👍 😂 😮 😢 🙏), Répondre,
    Copier, Modifier (message reçu ≠ possible), Épingler, Favoris, Informations
    (Envoyé / Distribué / Lu, « Lu par » en groupe), Supprimer (pour moi /
    pour tous — expéditeur uniquement) ;
  - composer : état vide / texte / réponse (citation + ×) / modification /
    enregistrement vocal (timer + waveform) ;
  - pièces jointes : Document, Caméra, Galerie, Audio, Localisation, Contact,
    Sondage (formulaire complet), Événement (formulaire complet) — envois
    réels vers le serveur ;
  - messages en attente : livrés automatiquement à la reconnexion (événement
    `pending`), accusés de lecture mis à jour en direct ;
  - protocole complet documenté dans `PROTOCOL.md`.
- **Thème** : sombre premium (défaut) + tokens clairs prêts à l'emploi.

## Structure

```
lib/
  main.dart                     # entrée + URL du serveur
  theme.dart                    # tokens Kite (brand-spec.md)
  models.dart                   # User / Chat / Message / ServerEvent
  api.dart                      # client HTTP + WebSocket (repli SSE) (dart:io)
  screens/chat_list_screen.dart # liste des discussions
  screens/conversation_screen.dart # conversation complète
```

## Roadmap (dans l'ordre de la mission)
Groupes (création, membres, mentions) → Communautés → Appels (audio/vidéo/groupe)
→ Confidentialité → Appareils liés → Stockage → Personnalisation (thème, bulles,
navigation) → Responsive tablette/desktop → Animations & polish.

> État de compilation (vérifié sur cette machine avec Flutter 3.47.2 / Dart 3.13) :
> `flutter analyze` → **No issues found**, `flutter build bundle` → OK (kernel 44 Mo),
> `flutter test` → **All tests passed** (smoke test liste + état d'erreur hors-ligne).
> Note : `dart:io` est utilisé, donc pas de cible Web pour l'instant (Android/iOS/Windows/Linux OK).
>
> Les builds natifs (APK / Windows exe) nécessitent respectivement un JDK + licences
> Android, et Visual Studio C++ — absents de cette machine.
