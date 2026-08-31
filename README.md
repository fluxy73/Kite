# Kite — Messagerie (prototype)

Prototype de messagerie moderne (fonctionnellement inspirée de WhatsApp, **sans
onglet Actus, sans Statuts, sans Chaînes**) : client **Flutter** (Android, iOS,
Windows, Linux, Web) + serveur **Go**, avec état local mocké **persisté côté
serveur** et temps réel **WebSocket** (repli **SSE**). Pas de backend réel, pas
de chiffrement réel : tout est simulé, mais chaque bouton a une interaction
fonctionnelle.

## Architecture

| Dossier | Rôle |
|---|---|
| `server/` | API REST Go + hub temps réel (WS/SSE), données JSON persistées (`data/kite.json`), seed automatique |
| `app/` | Client Flutter `kite` : design system (`theme.dart`), modèles miroirs (`models.dart`), client API (`api.dart`) |
| `screens/` + `*.html` | Maquettes HTML historiques (web, tablette, desktop) — la cible moderne est l'app Flutter |
| `PROTOCOL.md` | Protocole détaillé : REST + temps réel (WebSocket/SSE) |
| `brand-spec.md` | Spec du design system |

## Écrans (app Flutter)

| Écran | Fichier | Contenu |
|---|---|---|
| Shell 3 onglets (Discussions / Communautés / Appels) | `home_shell.dart` | navigation + chargement de `/api/shell` |
| Discussions | `chat_list_screen.dart` | liste des conversations, groupes, badges non-lus |
| Conversation | `conversation_screen.dart` | messages (texte, image, vidéo, document, audio, sondage…), réactions, réponse, édition, suppression, transfert, infos, épinglés |
| Communautés | `communities_screen.dart` | liste, détail, création, ajout de groupes |
| Appels | `calls_screen.dart` | favoris, récents (badge « Manqué »), **appels planifiés** (création, rappel, suppression), lien d'appel |
| Appel en cours | `calls_screen.dart` | **groupe** : grille responsive, partage d'écran, réactions · **1:1 vidéo** : flou d'arrière-plan, mode portrait |
| Appel entrant | `incoming_call_screen.dart` | sonnerie avec compte à rebours 30 s, accepter / refuser (manqué si timeout) |
| Rappel d'appel planifié | `reminder_center.dart` + `main.dart` | popup quand un appel avec rappel arrive à moins d'1 h |

## API (serveur Go)

Authentification mockée : paramètre `?userId=` sur chaque requête.

| Méthode | Route | Description |
|---|---|---|
| GET | `/api/health` | santé du service |
| GET/POST | `/api/users` | liste / crée un utilisateur |
| GET/POST | `/api/chats` | conversations / création (DM, groupe) |
| GET/POST | `/api/chats/{id}/messages` | messages (marque lu) / envoi |
| POST | `/api/messages/{id}/{react\|edit\|delete\|vote}` | réaction, édition, suppression, vote de sondage |
| GET | `/api/shell` | agrégat `{users, chats, communities, calls, scheduledCalls}` |
| GET/POST | `/api/communities` | liste / crée une communauté (avec groupes) |
| POST | `/api/calls/log` | journalise un appel (message `call`) |
| POST | `/api/calls/initiate` | initie un appel → broadcast `call` (sonnerie) |
| POST | `/api/calls/respond` | `accepted` \| `declined` \| `missed` → broadcast `call_respond` |
| GET/POST/PATCH/DELETE | `/api/scheduled-calls` | liste / crée / bascule le rappel / supprime un appel planifié |
| GET | `/api/events` | temps réel **SSE** (repli) |
| GET | `/api/ws` | temps réel **WebSocket** (primaire) |

## Temps réel

- **WebSocket** `GET /api/ws` (primaire), **SSE** `GET /api/events` (repli automatique côté client).
- Événements : `message`, `react`, `edit`, `delete`, `vote`, `read`, `pending`, `shell`, `call`, `call_respond`.

## Données & seed

- Persistance JSON (`data/kite.json`), re-seed automatique si le format change (`seedVersion`).
- Identité par défaut : `u-julien` (contacts : Lucas, Emma, Thomas, Sarah…).
- Groupes de démo, communautés, appels (récents + planifiés) pré-seedés.

## Tests

| Cible | Fichier | Contenu |
|---|---|---|
| Flutter | `app/test/widget_test.dart` | 3 tests widget : état hors-ligne + « Réessayer », popup de rappel d'appel planifié, options de l'appel vidéo 1:1 (flou, portrait) |
| Serveur | — | vérifications `go vet` / `go build` + flux e2e manuels (curl / WebSocket) |

## Démarrage

Serveur (port `:8080` par défaut) :

```bash
cd server
go run .
# KITE_ADDR=:8080 KITE_DATA=data/kite.json  (variables d'env optionnelles)
```

App Flutter :

```bash
cd app
flutter run -d windows     # ou -d linux / -d chrome / -d android
# URL de l'API : --dart-define=KITE_API=http://localhost:8080
# Émulateur Android : KITE_API=http://10.0.2.2:8080
```

## Vérifications

```bash
cd server && go vet ./... && go build ./...
cd app && flutter analyze && flutter test && flutter build bundle
```

## Structure

```
server/   main.go · api.go · store.go · hub.go · ws.go   (API + temps réel + persistance)
app/lib/  main.dart · api.dart · models.dart · theme.dart
          call_center.dart · reminder_center.dart · screens/
app/test/ widget_test.dart
PROTOCOL.md   protocole REST + temps réel
brand-spec.md design system
screens/      maquettes HTML historiques
```

Détails du protocole (formats JSON, événements, codes HTTP) : voir `PROTOCOL.md`.

## Roadmap / Fonctionnalités à venir

Fonctionnalités prévues (non implémentées aujourd'hui, le prototype reste en
state local mocké) :

**Communication réelle**
- Audio/vidéo réels (WebRTC) à la place des flux simulés.
- Chiffrement de bout en bout réel (clés, sessions).
- Notifications push (appels entrants et messages hors app).

**Backend**
- Authentification réelle (comptes, sessions) au lieu de `?userId=`.
- Persistance multi-utilisateurs (base de données), historique illimité.
- Gestion des messages en attente côté serveur (files par utilisateur).

**Messagerie**
- Recherche globale (messages, contacts), archivage et sauvegarde.
- Enregistrement vocal et vidéo réels, statuts de lecture précis.
- Sondages avancés, réactions multiples, épinglés persistés.

**Appels**
- Appel entrant hors application (push + sonnerie système).
- Journal d'appels complet (durée, sens, manqués) côté serveur.
- Rappels récurrents pour les appels planifiés.

**Plateformes & distribution**
- Builds finalisés Android/iOS/Windows/Linux, PWA.
- Synchronisation multi-appareils (compte unique).

Chaque item de cette liste sera traité comme une évolution incrémentale de la
base existante, en conservant le design system actuel.
