# Kite Server (Go)

Backend mock de la messagerie Kite. Persistance JSON, temps réel via
**WebSocket** (primaire, `github.com/coder/websocket` — zéro dépendance transitive)
avec **SSE en repli**, file d'attente des messages reçus hors-ligne
(« messages en attente »). Protocole documenté dans `PROTOCOL.md` (racine).

## Lancer

```bash
go run .                 # écoute sur :8080
KITE_ADDR=:9090 go run . # autre port
KITE_DATA=/tmp/kite.json # autre fichier de données
```

Ou compiler un binaire unique (idéal serveur Linux) :

```bash
GOOS=linux GOARCH=amd64 go build -o kite-server-linux .
./kite-server-linux
```

Le seed (5 utilisateurs, 3 conversations, messages de démo) est créé
automatiquement au premier lancement.

## API

| Méthode | Route | Description |
|---|---|---|
| GET | `/api/health` | santé du service |
| GET/POST | `/api/users?userId=` | liste / crée un utilisateur |
| GET/POST | `/api/chats?userId=` | conversations de l'utilisateur (avec dernier message, non-lus, en ligne) / crée un chat |
| GET/POST | `/api/chats/{id}/messages?userId=` | messages (marque comme lu) / envoie un message |
| POST | `/api/messages/{id}/react` | bascule une réaction `{userId, emoji}` |
| POST | `/api/messages/{id}/edit` | modifie `{userId, text}` (expéditeur uniquement) |
| POST | `/api/messages/{id}/delete` | supprime `{userId, mode: "me"\|"all"}` |
| POST | `/api/messages/{id}/vote` | vote à un sondage `{userId, optionIndex}` |
| GET | `/api/ws?userId=` | **temps réel WebSocket** : événements JSON + `pending` + relecture `sync` |
| GET | `/api/events?userId=&lastEventId=` | repli SSE (mêmes événements) |

### Types de messages supportés
`text`, `image`, `video`, `videonote`, `gif`, `sticker`, `document`,
`voice`, `audio`, `contact`, `location`, `poll`, `event`, `call`, `system`.

### Messages en attente (offline)
Quand un membre est hors-ligne, chaque message reçu est mis en file
(`data/kite.json` → `pending`). Au premier connect SSE, il est livré via un
événement `pending`. Les accusés de lecture (`readBy`, `deliveredTo`) sont
maintenus et diffusés via l'événement `read`.
