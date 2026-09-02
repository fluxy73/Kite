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
| POST | `/api/chats/{id}/mute` | met en sourdine pour moi avec expiration (`8h` | `1w` | `always`), ou démute (`off`) |
| POST | `/api/typing` | diffuse l'indicateur de saisie (éphémère, event `typing`) |
| GET/POST/PATCH/DELETE | `/api/scheduled-calls` | liste / crée / bascule le rappel / supprime un appel planifié |
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
  chaque envoi (marqué livré + lu) pour rendre la conversation vivante.
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

## Roadmap / Fonctionnalités à venir

Fonctionnalités prévues (non implémentées aujourd'hui) :

**Communication réelle**
- Chiffrement de bout en bout réel (clés, sessions).
- Notifications push (appels entrants et messages hors app).
- Serveur TURN pour les appels WebRTC derrière NAT strict.
- Appels de groupe en WebRTC (mesh ou SFU) — actuellement simulés.

**Backend**
- Authentification réelle (comptes, sessions) au lieu de `?userId=`.
- Persistance multi-utilisateurs (base de données), historique illimité.

**Messagerie**
- Sauvegarde/export de l'historique.
- Enregistrement vocal et vidéo réels, statuts de lecture précis.
- Sondages avancés, réactions multiples.

**Appels**
- Appel entrant hors application (push + sonnerie système).
- Rappels récurrents pour les appels planifiés.

**Plateformes & distribution**
- Synchronisation multi-appareils : fusion de l'état hors-ligne local avec le
  serveur à la reconnexion.
- Builds finalisés iOS (TestFlight), PWA.

Chaque item de cette liste sera traité comme une évolution incrémentale de la
base existante, en conservant le design system actuel.
