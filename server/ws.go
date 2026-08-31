package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// wsConn sérialise les écritures WebSocket (un seul writer à la fois).
type wsConn struct {
	conn    *websocket.Conn
	writeMu sync.Mutex
}

func (c *wsConn) writeJSON(ctx context.Context, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.writeBytes(ctx, b)
}

func (c *wsConn) writeBytes(ctx context.Context, b []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return c.conn.Write(ctx, websocket.MessageText, b)
}

// handleWS est le point d'entrée temps réel par WebSocket.
//
//	GET /api/ws?userId=<id>
//
// Serveur -> client : événements JSON {id, type, chatId, data}
//   - {type:"pending", data:[messages]} au connect.
//
// Client -> serveur : {"type":"sync","since":N}  (relecture après N)
//
//	{"type":"ping"}            (-> {type:"pong"})
func (a *api) handleWS(w http.ResponseWriter, r *http.Request) {
	uid := r.URL.Query().Get("userId")
	if uid == "" {
		httpError(w, 400, "userId requis")
		return
	}
	if _, ok := a.store.userByID(uid); !ok {
		httpError(w, 404, "utilisateur inconnu")
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return // la poignée de main a échoué, l'erreur HTTP est déjà écrite
	}
	c := &wsConn{conn: conn}
	defer conn.Close(websocket.StatusNormalClosure, "")

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	ch := a.hub.subscribe(uid)
	defer a.hub.unsubscribe(uid, ch)

	// 1) Livraison immédiate des messages en attente (reçus hors-ligne).
	if pending := a.store.drainPending(uid); len(pending) > 0 {
		_ = c.writeJSON(ctx, map[string]any{"type": "pending", "chatId": "", "data": pending})
	}

	// 2) Writer : diffusion des événements temps réel + heartbeat (ping toutes les 25 s).
	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		heartbeat := time.NewTicker(25 * time.Second)
		defer heartbeat.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-ch:
				if err := c.writeBytes(ctx, b); err != nil {
					return
				}
			case <-heartbeat.C:
				pingCtx, pingCancel := context.WithTimeout(ctx, 5*time.Second)
				err := conn.Ping(pingCtx)
				pingCancel()
				if err != nil {
					return
				}
			}
		}
	}()

	// 3) Reader : messages de contrôle + réponse automatique aux pings.
	for {
		mt, data, err := conn.Read(ctx)
		if err != nil {
			cancel()
			break
		}
		// Les trames ping/pong/close sont gérées en interne par la librairie.
		if mt == websocket.MessageText {
			a.handleWSControl(ctx, c, uid, data, ch)
		}
	}
	<-writeDone
}

// handleWSControl traite les messages client -> serveur.
func (a *api) handleWSControl(ctx context.Context, c *wsConn, uid string, data []byte, ch chan []byte) {
	var msg struct {
		Type  string `json:"type"`
		Since int64  `json:"since"`
	}
	if err := json.Unmarshal(data, &msg); err != nil {
		return
	}
	switch msg.Type {
	case "sync":
		// Relecture des événements manqués depuis l'identifiant `since`.
		// Les doublons éventuels sont éliminés côté client (upsert par id).
		for _, ev := range a.hub.replay(msg.Since) {
			if !a.store.memberOf(uid, ev.ChatID) {
				continue
			}
			b, _ := json.Marshal(ev)
			select {
			case ch <- b:
			case <-ctx.Done():
				return
			}
		}
	case "ping":
		_ = c.writeJSON(ctx, map[string]any{"type": "pong"})
	}
}
