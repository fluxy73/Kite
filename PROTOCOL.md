# Kite — Protocole de messagerie (mock)

Transport temps réel : **WebSocket** (primaire) + **SSE** (repli). REST pour
toutes les opérations. Pas d'authentification réelle : l'utilisateur est
identifié par `userId` (query param pour REST/SSE, même param pour le WS).

## 1. REST

| Méthode | Route | Corps / Query | Description |
|---|---|---|---|
| GET | `/api/health` | — | santé du service |
| GET/POST | `/api/users` | `{name}` | liste / crée un utilisateur |
| GET/POST | `/api/chats` | `?userId=` · `{type,name,memberIds}` | conversations / création (DM, group) |
| GET/POST | `/api/chats/{id}/messages` | `?userId=` · `{senderId,type,text,media,replyTo}` | messages (marque lu) / envoi |
| POST | `/api/messages/{id}/react` | `{userId, emoji}` | bascule une réaction |
| POST | `/api/messages/{id}/edit` | `{userId, text}` | modifie (expéditeur seul) |
| POST | `/api/messages/{id}/delete` | `{userId, mode: "me"\|"all"}` | supprime (all : expéditeur seul) |
| POST | `/api/messages/{id}/vote` | `{userId, optionIndex}` | vote à un sondage |
| GET | `/api/shell` | `?userId=` | agrégat Appels + Communautés + Discussions (`{users,chats,communities,calls}`) |
| GET/POST | `/api/communities` | `?userId=` · `{name,description,groupIds}` | liste / crée une communauté (avec groupes join) |
| POST | `/api/calls/log` | `{userId,chatId,kind,direction}` | journalise un appel (message `call` dans le chat) |
| POST | `/api/calls/initiate` | `{userId,chatId,kind}` | initie un appel → broadcast WebSocket/SSE `{type:"call"}` (sonnerie) |
| POST | `/api/calls/respond` | `{userId,callId,status: accepted|declined}` | répond à un appel entrant → broadcast `{type:"call_respond"}` |

Codes : `200/201` OK · `400` paramètre manquant · `403` action interdite
(non-expéditeur, non-membre) · `404` ressource inconnue.

## 2. Modèle de message

```json
{
  "id": "m-a1b2c3d4",
  "chatId": "c-lucas",
  "senderId": "u-julien",
  "type": "text",
  "text": "Salut !",
  "media": { "duration": 34 },
  "createdAt": 1788183949796,
  "edited": false,
  "deleted": false,
  "deletedFor": [],
  "reactions": { "❤️": ["u-julien", "u-emma"] },
  "replyTo": "m-101",
  "readBy": ["u-lucas"],
  "deliveredTo": ["u-lucas"]
}
```

`type` : `text, image, video, videonote, gif, sticker, document, voice,
audio, contact, location, poll, event, call, system`.

`media` (selon le type) :
- `voice`/`audio` : `{duration}` (secondes)
- `document` : `{ext, size, pages}`
- `image`/`video`/`gif`/`videonote` : `{name, once?, album?}`
- `poll` : `{options: [], votes: [], voters: [], multi?}`
- `event` : `{date, time, location, link, participants, maybe}`
- `contact` : `{name, phone}` · `location` : `{name, live?}`

## 3. Temps réel — WebSocket (primaire)

```
GET /api/ws?userId=<id>     (RFC 6455, upgrade standard)
```

### Serveur → client (trames texte JSON)

```json
{ "id": 12, "type": "message", "chatId": "c-lucas", "data": { …message… } }
```

`id` : identifiant d'événement croissant (serveur), sert au resync.
`type` : `message, react, edit, delete, vote, read, pending, pong`.

- `message` : `data` = le message complet (envoi, y compris par un autre membre).
- `react` : `data` = `{id, reactions}` (état complet des réactions).
- `edit` : `data` = le message modifié (`edited: true`).
- `delete` : `data` = `{id, deleted, deletedFor, userId}`.
- `vote` : `data` = `{id, media}` (sondage avec votes/voters à jour).
- `read` : `data` = `{chatId, userId}` (accusé de lecture).
- `pending` : `data` = **tableau** de messages reçus hors-ligne, envoyé une
  seule fois juste après la connexion.
- `pong` : réponse à `{"type":"ping"}`.

### Client → serveur (trames texte JSON)

```json
{ "type": "sync", "since": 41 }   // relecture des événements > since
{ "type": "ping" }                // keepalive applicatif -> {type:"pong"}
```

Le client envoie `sync` dès l'ouverture (`since` = dernier id connu, 0 sinon).
Le serveur rejoue les événements du journal (`chatId` filtré par appartenance),
puis les nouveaux arrivent en direct. **Les doublons sont éliminés côté client
(upsert par id)** — un événement peut arriver une fois en replay et une fois en
live.

Heartbeat serveur : `ping` de trame toutes les 25 s (détection de déconnexion).

### Repli — SSE

`GET /api/events?userId=&lastEventId=` : mêmes événements, encodage SSE
(`id:` / `event:` / `data:`), même événement `pending` au connect, relecture
via `lastEventId`. Les deux transports sont interchangeables côté client.

## 4. Messages en attente (offline)

1. Un membre est hors-ligne (aucune connexion WS/SSE active).
2. Un autre membre envoie un message → il est persisté **et** mis en file
   `pending` pour chaque destinataire hors-ligne.
3. À la reconnexion : événement `pending` avec tous les messages reçus
   pendant l'absence, puis flux live normal.
4. `readBy`/`deliveredTo` : la lecture (`GET messages` ou événement `read`)
   met à jour les accusés, diffusés aux autres membres.

## 5. Reconnexion (résumé)

```
1. WS connect ? sinon SSE connect (même logique)
2. drain pending -> événement "pending" (tableau)
3. envoyer {"type":"sync","since":<dernier id connu>}  (SSE : lastEventId)
4. rejouer les événements manqués (journal serveur, cap 1000)
5. écouter les événements live, upsert par id (déduplication)
6. heartbeat serveur 25 s ; en cas de coupure, revenir en 1.
```
