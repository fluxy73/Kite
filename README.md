# Kite — Messagerie (prototype)

Prototype de messagerie moderne (fonctionnellement inspirée de WhatsApp, **sans
onglet Actus, sans Statuts, sans Chaînes**) : client **Flutter** (Android, iOS,
Windows, Linux, Web) + serveur **Go** optionnel. **L'app fonctionne hors-ligne
par défaut** : état persisté localement (JSON), envoi/réception de messages,
appels 1:1 en **WebRTC réel** (audio/vidéo pair-à-pair, signalisation relayée
par le serveur en mode connecté) et temps réel **WebSocket** (repli **SSE**)
quand un serveur est configuré. Pas de chiffrement réel : chaque bouton a une
interaction fonctionnelle.

## Architecture

| Dossier | Rôle |
|---|---|
| `server/` | API REST Go + hub temps réel (WS/SSE), données JSON persistées (`data/kite.json`), seed automatique |
| `app/` | Client Flutter `kite` : design system (`theme.dart`), modèles (`models.dart`), client API (`api.dart`), **stack hors-ligne** (`local_store.dart` + `offline_api.dart`), moteur WebRTC (`call_engine.dart`), sonde de connexion (`server_status.dart`) |
| `screens/` + `*.html` | Maquettes HTML historiques (web, tablette, desktop) — la cible moderne est l'app Flutter |
| `PROTOCOL.md` | Protocole détaillé : REST + temps réel (WebSocket/SSE) |
| `brand-spec.md` | Spec du design system |

## Écrans (app Flutter)

| Écran | Fichier | Contenu |
|---|---|---|
| Shell 2 onglets (Discussions / Appels), **vue 2 panneaux adaptative** | `home_shell.dart` | navigation adaptative (LayoutBuilder) : ≥ 900 px logiques, Discussions affiche liste (380 px) + conversation côte à côte ; écran étroit : onglets plein écran. Badge total non-lus sur l'onglet. Données depuis `/api/shell` ou la base locale |
| Discussions | `chat_list_screen.dart` | liste des conversations, groupes, badges non-lus, **conversations archivées** (menu appui long + section dédiée), **création de DM** |
| Conversation | `conversation_screen.dart` | messages (texte, image, vidéo, document, audio, sondage…), réactions, réponse, édition, suppression, transfert, infos, épinglés, **favoris** (⭐ persistés), **indicateur de saisie**, **brouillons persistés** |
| Appels | `calls_screen.dart` | favoris, récents (badge « Manqué »), **appels planifiés** (création, rappel, suppression), lien d'appel, **import des contacts de l'appareil** (matching serveur ou local hors-ligne) |
| Appel en cours | `calls_screen.dart` · `real_call_screen.dart` | **1:1 temps réel** : WebRTC (`flutter_webrtc`), vidéo distante + PiP local, flou d'arrière-plan, mode portrait, muet / caméra / haut-parleur · **groupe** : grille responsive, partage d'écran, réactions (simulé) |
| Appel entrant | `incoming_call_screen.dart` | sonnerie avec compte à rebours 30 s, accepter / refuser (manqué si timeout) |
| Rappel d'appel planifié | `reminder_center.dart` + `main.dart` | popup quand un appel avec rappel arrive à moins d'1 h |
| Indicateur de connexion | `server_status.dart` | pastille **En ligne / Connexion… / Hors ligne** dans la barre d'onglets (sonde `GET /api/health` toutes les 10 s) |
| Recherche globale | `global_search_screen.dart` | recherche réelle dans les noms de discussions **et** le texte des messages (serveur ou base locale) — ouvre la conversation |

## API (serveur Go)

Authentification mockée : paramètre `?userId=` sur chaque requête.

| Méthode | Route | Description |
|---|---|---|
| GET | `/api/health` | santé du service |
| GET/POST | `/api/users` | liste / crée un utilisateur |
| GET/POST | `/api/chats` | conversations / création (DM, groupe) |
| GET/POST | `/api/chats/{id}/messages` | messages (marque lu) / envoi |
| POST | `/api/messages/{id}/{react\|edit\|delete\|vote}` | réaction, édition, suppression, vote de sondage |
| GET | `/api/shell` | agrégat `{users, chats, calls, scheduledCalls}` |
| POST | `/api/contacts/match` | matche les contacts de l'appareil (nom + téléphones) contre les utilisateurs enregistrés |
| POST | `/api/calls/log` | journalise un appel (message `call`) |
| POST | `/api/calls/initiate` | initie un appel → broadcast `call` (sonnerie) |
| POST | `/api/calls/respond` | `accepted` \| `declined` \| `missed` \| `ended` → broadcast `call_respond` |
| POST | `/api/calls/signal` | relaie la signalisation **WebRTC** (`offer` \| `answer` \| `ice`) aux participants d'un appel |
| POST | `/api/messages/{id}/star` | marque/démarque le message en favori pour moi (persistance) |
| POST | `/api/chats/{id}/archive` | archive/désarchive la conversation pour moi |
| POST | `/api/chats/{id}/pin` | épingle/détache la conversation pour moi (persistance, tri en tête) |
| POST | `/api/chats/{id}/delete` | supprime la discussion pour moi (les autres membres la conservent ; un nouveau message la fait renaître) |
| POST | `/api/chats/{id}/mute` | met en sourdine pour moi avec expiration (`8h` | `1w` | `always`), ou démute (`off`) — pendant la sourdine : badge non-lus masqué (compteur à 0, messages non marqués lus) et indicateur de saisie non diffusé vers moi (live et relecture) |
| POST | `/api/chats/{id}/disappearing` | minuteur de **messages éphémères** de la conversation (`0` = off, `86400000` = 24 h, `604800000` = 7 j, `7776000000` = 90 j) — les messages envoyés pendant que le minuteur est actif portent `expiresAt` et disparaissent pour tous après la durée (sweep serveur 15 s + event `expired`, filtrage à la lecture) ; message système diffusé à chaque changement |
| POST | `/api/chats/{id}/notifs` | préférences de notification pour moi : `priority` (`low`/`default`/`high`), `sound` et `preview` (booléens) ; corps vide = remise aux défauts — l'aperçu désactivé masque le texte du message dans les notifications |
| GET/POST | `/api/notif-defaults` | défauts de notification **globaux** de l'utilisateur (toutes ses conversations sans réglage propre) ; POST corps vide = remise aux défauts de l'app ; transportés par `/api/shell` (`notifDefaults`) — chaîne de résolution : conversation > global > défauts de l'app |
| POST | `/api/typing` | diffuse l'indicateur de saisie (éphémère, event `typing`) — sauf aux membres qui ont mis la conversation en sourdine |
| GET/POST/PATCH/DELETE | `/api/scheduled-calls` | liste / crée / bascule le rappel / supprime un appel planifié |
| GET/POST/DELETE | `/api/folders` | dossiers de conversations **par utilisateur** (façon Telegram) — liste / crée / renomme / ajoute-retire une conversation / supprime ; isolation stricte entre utilisateurs |
| GET | `/api/events` | temps réel **SSE** (repli) |
| GET | `/api/ws` | temps réel **WebSocket** (primaire) |

## Temps réel

- **WebSocket** `GET /api/ws` (primaire), **SSE** `GET /api/events` (repli automatique côté client).
- Événements : `message`, `react`, `edit`, `delete`, `vote`, `read`, `pending`, `shell`, `call`, `call_respond`, `call_signal` (signalisation WebRTC), `typing` (indicateur de saisie). En mode hors-ligne, un flux local équivalent alimente l'UI.

## Mode hors-ligne (par défaut)

Sans `KITE_API`, l'app est **autonome** — aucun serveur requis :

- **Base locale JSON** (`local_store.dart`) persistée avec écriture atomique :
  `%APPDATA%/kite/kite-local.json` (Windows), `$HOME/kite/kite-local.json`
  (Linux), `~/Library/Application Support/kite/` (macOS). Seed équivalent au
  serveur (utilisateurs, DM, groupe, messages, appels, appel planifié).
- **`OfflineApi`** implémente toute la surface de `KiteApi` : messages,
  réactions, édition, suppression, votes, journal d'appels, appels planifiés,
  matching de contacts (normalisation téléphone + repli par nom, même logique
  que le serveur). Un **écho simulé** d'un correspondant arrive ~3 s après
  chaque envoi (marqué livré + lu) pour rendre la conversation vivante, et
  déclenche une **notification locale** comme un vrai message entrant.
- **Messages éphémères** : minuteur par conversation (24 h / 7 j / 90 j) rejoué en local — horodatage `expiresAt` à l'envoi, sweep à chaque tick, filtrage à la lecture (parité avec le serveur).
- **Verrou de discussion** : code PIN à 4 chiffres par conversation, stocké **haché (SHA-256)** sur l'appareil (`kite-chatlock.json`) — aperçu masqué dans la liste, porte PIN à l'ouverture, re-verrouillage en quittant l'écran et au retour au premier plan (auto-lock). Réglage volontairement **hors-serveur** : il protège l'accès local à la conversation, comme les brouillons.
- **Dossiers de conversations** : organisation Telegram-style — onglets épinglés (Toutes · Non lues · dossiers · +), appartenance multiple, miroir `LocalStore` persisté à l'identique du serveur.
- **Notifications locales** de messages entrants : supprimées pour les
  conversations **muettes** (`mutedFor`), les messages à soi-même et les
  conversations ouvertes à l'écran — dans les deux modes (serveur et
  hors-ligne).
- **Bannière OS en arrière-plan** (`flutter_local_notifications`) : quand
  l'app n'est pas au premier plan, la notification part en alerte système
  (toast Windows, canal Android « Messages » haute importance, iOS/macOS/
  Linux) avec demande de permission ; un appui sur la bannière ouvre la
  conversation (et efface la bannière). Au premier plan : snackbar in-app.
  Si le plugin ou la permission est indisponible, bascule silencieuse en
  snackbars seuls — jamais de crash.
- **Défauts de notification globaux** (écran « Notifications » dans les
  options de la liste des discussions) : priorité, son et aperçu pour
  toutes les conversations d'un coup. Le réglage propre à une conversation
  (fiche infos) **prime** sur ces défauts, qui priment eux-mêmes sur les
  défauts de l'app — résolution appliquée à chaque notification dans les
  deux modes (serveur et hors-ligne).
- **Brouillons** par conversation (`drafts.dart`), persistés entre sessions
  (fichier `kite-drafts.json`, TTL 30 jours) ; effacés après l'envoi.
- Les **appels 1:1 WebRTC** nécessitent la signalisation serveur : hors-ligne,
  l'app bascule automatiquement sur l'écran d'appel simulé.
- L'indicateur de connexion affiche « Hors ligne » en gris (mode local normal,
  pas une erreur) ; il passe en rouge seulement si un serveur configuré est
  injoignable.

## Données & seed

- Persistance JSON (`data/kite.json`), re-seed automatique si le format change (`seedVersion`).
- Identité par défaut : `u-julien` (contacts : Lucas, Emma, Thomas, Sarah…).
- Groupes de démo, appels (récents + planifiés) pré-seedés. L'app hors-ligne
  entretient son propre jeu de données équivalent.

## Tests

| Cible | Fichier | Contenu |
|---|---|---|
| Flutter | `app/test/widget_test.dart` | 3 tests widget : état hors-ligne + « Réessayer », popup de rappel d'appel planifié, options de l'appel vidéo 1:1 (flou, portrait) |
| Flutter | `app/test/adaptive_shell_test.dart` | shell réel : onglets étroits vs **2 panneaux larges** avec conversation rendue dans le volet droit |
| Flutter | `app/test/offline_lifecycle_test.dart` | cycle hors-ligne complet : seed → envoi → écho → réaction/édition/suppression → vote → appels → matching contacts → **persistance après redémarrage** |
| Flutter | `app/test/call_center_test.dart` · `server_status_test.dart` | routage des signaux WebRTC / sonde de connexion et badge |
| Flutter | `app/test/folders_test.dart` | dossiers : CRUD + appartenance multiple + filtrage, **persistance après redémarrage**, isolation |
| Flutter | `app/test/disappearing_messages_test.dart` | messages éphémères : minuteur → horodatage → disparition au sweep → **persistance après redémarrage** → désactivation |
| Flutter | `app/test/chat_lock_test.dart` | verrou de discussion : pose du PIN (4 chiffres) → déverrouillage → retrait → **persistance après redémarrage** → auto-lock |
| Flutter | `app/test/new_features_test.dart` | favoris, archivage et brouillons : état + **persistance disque** (double « process ») |
| Serveur | — | vérifications `go vet` / `go build` + flux e2e manuels (curl / WebSocket) |

## Démarrage

### Mode hors-ligne (défaut, aucun serveur)

```bash
cd app
flutter run -d android     # ou windows / linux / ios
# Sans KITE_API : base locale, données persistées, écho simulé.
```

### Mode connecté (serveur Go)

Serveur (port `:8080` par défaut) :

```bash
cd server
go run .
# KITE_ADDR=:8080 KITE_DATA=data/kite.json  (variables d'env optionnelles)
```

App pointée sur le serveur :

```bash
cd app
flutter run --dart-define=KITE_API=http://localhost:8080
# Émulateur Android : KITE_API=http://10.0.2.2:8080
# Distant (tunnel, LAN) : KITE_API=https://votre-tunnel.example
```

En mode connecté : temps réel WebSocket/SSE, appels 1:1 **WebRTC réels**
(signalisation relayée par `/api/calls/signal`), import de contacts matché
côté serveur. L'indicateur dans la barre d'onglets confirme l'état réel de la
connexion (sonde `/api/health` toutes les 10 s).

## Vérifications

```bash
cd server && go vet ./... && go build ./...
cd app && flutter analyze && flutter test && flutter build bundle
```

## Structure

```
server/   main.go · api.go · store.go · hub.go · ws.go   (API + temps réel + persistance)
app/lib/  main.dart · api.dart · models.dart · theme.dart
          local_store.dart · offline_api.dart      (stack hors-ligne)
          call_center.dart · call_engine.dart      (appels + WebRTC)
          server_status.dart · reminder_center.dart · screens/
app/test/ widget_test.dart · adaptive_shell_test.dart · offline_lifecycle_test.dart
          call_center_test.dart · server_status_test.dart
PROTOCOL.md   protocole REST + temps réel
brand-spec.md design system
screens/      maquettes HTML historiques
```

Détails du protocole (formats JSON, événements, codes HTTP) : voir `PROTOCOL.md`.

## Historique des livraisons

| Version | Contenu | PRs |
|---|---|---|
| [v0.1.0](https://github.com/fluxy73/Kite/releases/tag/v0.1.0) | Première version complète : messagerie hors-ligne d'abord, serveur Go optionnel, appels 1:1 WebRTC réels, écrans Discussions/Appels, mise en page adaptative (2 panneaux sur grand écran) | #14 |
| [v0.1.1](https://github.com/fluxy73/Kite/releases/tag/v0.1.1) | Sourdine par conversation avec expiration (`8h` / `1w` / `always`), persistée côté serveur comme pin/archive | #15 |
| [v0.1.2](https://github.com/fluxy73/Kite/releases/tag/v0.1.2) | Sourdine : badge non-lus masqué + indicateur de saisie supprimé (live, relecture SSE et WS) ; notifications locales des messages entrants, respect de la sourdine, y compris hors-ligne (échos simulés notifiés) | #16, #17 |
| [v0.1.3](https://github.com/fluxy73/Kite/releases/tag/v0.1.3) | Bannières OS en arrière-plan (`flutter_local_notifications`, Android/iOS/macOS/Windows/Linux, repli snackbars) ; préférences de notification par conversation (priorité, son, aperçu) ; correction de vie privée : les réglages d'un membre ne sont plus sérialisés aux autres | #18, #19 |
| [v0.1.4](https://github.com/fluxy73/Kite/releases/tag/v0.1.4) | Défauts de notification globaux (écran de réglages, chaîne de résolution avec les préférences par conversation) ; releases automatisées (workflow de build APK + publication à chaque tag, ci-dessous) | #20, #21, #23, #22 |
| [v0.1.5](https://github.com/fluxy73/Kite/releases/tag/v0.1.5) | Messages programmés (date/heure dans le composer, dispatch serveur automatique, livraison simulée hors-ligne, rappel local) ; messages éphémères (minuteur 24 h / 7 j / 90 j par conversation, sweep serveur, parité offline) ; verrou de discussion (code PIN 4 chiffres haché SHA-256 sur l'appareil, porte à l'ouverture, auto-lock au premier plan, aperçu masqué dans la liste) ; dossiers de conversations façon Telegram (onglets épinglés Toutes · Non lues · dossiers · +, persistés par utilisateur, appartenance multiple) | #24, #25, #26, #27 |

## Roadmap / Fonctionnalités à venir

Fonctionnalités prévues (non implémentées aujourd'hui) :

**Communication réelle**
- Chiffrement de bout en bout réel (clés, sessions).
- Notifications push réelles (FCM/APNs) quand l'app est fermée — les
  bannières OS de v0.1.3 couvrent l'app vivante en arrière-plan.
- Serveur TURN pour les appels WebRTC derrière NAT strict.
- Appels de groupe en WebRTC (mesh ou SFU) — actuellement simulés.

**Backend**
- Authentification réelle (comptes, sessions) au lieu de `?userId=`.
- Persistance multi-utilisateurs (base de données), historique illimité.

**Messagerie**
- Sauvegarde/export de l'historique.
- Traduction des messages (appui long).
- Livré en v0.1.5 : messages programmés, messages éphémères, verrou de discussion, dossiers de conversations.
- Enregistrement vocal et vidéo réels, statuts de lecture précis.
- Sondages avancés, réactions multiples.

**Appels**
- Appel entrant hors application (push + sonnerie système).
- Rappels récurrents pour les appels planifiés.

**Sécurité**
- Verrouillage biométrique de l'app entière (au lancement), en plus du verrou par conversation.

**Plateformes & distribution**
- Synchronisation multi-appareils : fusion de l'état hors-ligne local avec le
  serveur à la reconnexion.
- Builds finalisés iOS (TestFlight), PWA.

Chaque item de cette liste sera traité comme une évolution incrémentale de la
base existante, en conservant le design system actuel.
