package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

type api struct {
	store *Store
	hub   *Hub
	meID  string // utilisateur "moi" (Julien) pour le mode mock
}

func wJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	wJSON(w, code, map[string]string{"error": msg})
}

func readJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// cors applies dev-friendly CORS headers.
func cors(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next(w, r)
	}
}

func (a *api) userOrError(w http.ResponseWriter, r *http.Request) (string, bool) {
	uid := r.URL.Query().Get("userId")
	if uid == "" {
		httpError(w, 400, "userId requis")
		return "", false
	}
	if _, ok := a.store.userByID(uid); !ok {
		httpError(w, 404, "utilisateur inconnu")
		return "", false
	}
	return uid, true
}

// ---------- Users ----------

func (a *api) handleUsers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		users := a.store.state.Users
		sort.Slice(users, func(i, j int) bool { return users[i].Name < users[j].Name })
		wJSON(w, 200, users)
	case http.MethodPost:
		var body struct {
			Name string `json:"name"`
		}
		if err := readJSON(r, &body); err != nil || strings.TrimSpace(body.Name) == "" {
			httpError(w, 400, "name requis")
			return
		}
		u := a.store.addUser(strings.TrimSpace(body.Name))
		wJSON(w, 201, u)
	default:
		httpError(w, 405, "méthode non supportée")
	}
}

// ---------- Chats ----------

type chatSummary struct {
	Chat
	LastMessage *Message `json:"lastMessage,omitempty"`
	Unread      int      `json:"unread"`
	Online      int      `json:"online"`
}

func (a *api) handleChats(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	switch r.Method {
	case http.MethodGet:
		chats := a.store.chatsFor(uid)
		out := make([]chatSummary, 0, len(chats))
		for _, c := range chats {
			cs := chatSummary{Chat: c, Unread: a.store.unreadCount(c.ID, uid)}
			if lm := a.store.lastMessage(c.ID); lm != nil {
				cs.LastMessage = lm
			}
			for _, m := range c.MemberIDs {
				if a.hub.isOnline(m) {
					cs.Online++
				}
			}
			out = append(out, cs)
		}
		wJSON(w, 200, out)
	case http.MethodPost:
		var body struct {
			Type      string   `json:"type"`
			Name      string   `json:"name"`
			MemberIDs []string `json:"memberIds"`
		}
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
		members := append([]string{uid}, body.MemberIDs...)
		c := a.store.addChat(body.Type, body.Name, members, []string{uid})
		if body.Type == "group" {
			sys := a.store.addMessage(c.ID, uid, "system", fmt.Sprintf("Vous avez créé le groupe « %s »", body.Name), nil, "")
			a.hub.broadcastToUsers(members, Event{Type: "message", ChatID: c.ID, Data: mustJSON(sys)})
		}
		wJSON(w, 201, c)
	default:
		httpError(w, 405, "méthode non supportée")
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// ---------- Messages ----------

func (a *api) handleMessages(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	chatID := strings.TrimPrefix(r.URL.Path, "/api/chats/")
	chatID = strings.TrimSuffix(chatID, "/messages")
	if chatID == "" || !a.store.memberOf(uid, chatID) {
		httpError(w, 404, "conversation introuvable")
		return
	}

	switch r.Method {
	case http.MethodGet:
		msgs := a.store.chatMessages(chatID, uid)
		if a.store.markRead(chatID, uid) {
			chat, _ := a.store.chatByID(chatID)
			a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "read", ChatID: chatID, Data: mustJSON(map[string]string{"chatId": chatID, "userId": uid})})
		}
		wJSON(w, 200, msgs)
	case http.MethodPost:
		var body struct {
			SenderID string         `json:"senderId"`
			Type     string         `json:"type"`
			Text     string         `json:"text"`
			ReplyTo  string         `json:"replyTo"`
			Media    map[string]any `json:"media"`
		}
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
		if body.SenderID != uid {
			httpError(w, 403, "senderId != userId")
			return
		}
		if body.Type == "" {
			body.Type = "text"
		}
		m := a.store.addMessage(chatID, uid, body.Type, body.Text, body.Media, body.ReplyTo)
		chat, _ := a.store.chatByID(chatID)
		a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "message", ChatID: chatID, Data: mustJSON(m)})
		// Messages en attente : chaque membre hors-ligne reçoit une copie au prochain connect.
		for _, mid := range chat.MemberIDs {
			if mid == uid {
				continue
			}
			if !a.hub.isOnline(mid) {
				a.store.addPending(mid, m)
			}
		}
		wJSON(w, 201, m)
	default:
		httpError(w, 405, "méthode non supportée")
	}
}

// ---------- App shell (Discussions + Communautés + Appels) ----------

// communityView joins a community with its member group chats.
type communityView struct {
	Community
	Groups []Chat `json:"groups"`
}

func (a *api) communitiesFor(userID string, withGroups bool) []communityView {
	out := []communityView{}
	for _, cm := range a.store.state.Communities {
		groups := []Chat{}
		if withGroups {
			for _, gid := range cm.GroupIDs {
				if c, ok := a.store.chatByID(gid); ok && inSlice(c.MemberIDs, userID) {
					groups = append(groups, *c)
				}
			}
		}
		out = append(out, communityView{Community: cm, Groups: groups})
	}
	return out
}

func (a *api) handleShell(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	wJSON(w, 200, map[string]any{
		"users":       a.store.state.Users,
		"chats":       a.store.chatsFor(uid),
		"communities": a.communitiesFor(uid, true),
		"calls":       a.store.state.Calls,
	})
}

// handleCommunities lists communities and lets me create a new one.
func (a *api) handleCommunities(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	switch r.Method {
	case http.MethodGet:
		wJSON(w, 200, a.communitiesFor(uid, true))
	case http.MethodPost:
		var body struct {
			Name        string   `json:"name"`
			Description string   `json:"description"`
			GroupIDs    []string `json:"groupIds"`
		}
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
		if strings.TrimSpace(body.Name) == "" {
			httpError(w, 400, "name requis")
			return
		}
		cm := Community{
			ID:          newID("cm"),
			Name:        strings.TrimSpace(body.Name),
			Description: body.Description,
			GroupIDs:    body.GroupIDs,
			CreatedAt:   time.Now().UnixMilli(),
		}
		a.store.addCommunity(cm)
		wJSON(w, 201, cm)
	default:
		httpError(w, 405, "méthode non supportée")
	}
}

// handleCallLog logs a completed (or missed/running) call in a chat.
func (a *api) handleCallLog(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var body struct {
		ChatID    string `json:"chatId"`
		Kind      string `json:"kind"`      // audio | video
		Direction string `json:"direction"` // incoming | outgoing | missed
	}
	if err := readJSON(r, &body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}
	if !a.store.memberOf(uid, body.ChatID) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}
	if body.Direction == "" {
		body.Direction = "outgoing"
	}
	var text string
	if body.Kind == "video" {
		text = "📹 Appel"
	} else {
		text = "📞 Appel"
	}
	if body.Direction == "missed" {
		if body.Kind == "video" {
			text = "📹 Appel manqué"
		} else {
			text = "📞 Appel manqué"
		}
	}
	m := a.store.addMessage(body.ChatID, a.meID, "call", text, map[string]any{
		"kind": body.Kind, "direction": body.Direction,
	}, "")
	chat, _ := a.store.chatByID(body.ChatID)
	a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "message", ChatID: body.ChatID, Data: mustJSON(m)})
	wJSON(w, 201, m)
}

// ---------- Actions sur messages ----------
// ---------- SSE (temps réel + messages en attente) ----------

func (a *api) handleEvents(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var since int64
	if v := r.URL.Query().Get("lastEventId"); v != "" {
		since, _ = strconv.ParseInt(v, 10, 64)
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, 500, "streaming non supporté")
		return
	}

	writeEvent := func(ev Event) {
		fmt.Fprintf(w, "id: %d\nevent: %s\ndata: %s\n\n", ev.ID, ev.Type, ev.Data)
	}
	// Relecture des événements manqués.
	for _, ev := range a.hub.replay(since) {
		if !a.store.memberOf(uid, ev.ChatID) {
			continue
		}
		writeEvent(ev)
	}
	// Livraison des messages en attente (reçus hors-ligne).
	if pending := a.store.drainPending(uid); len(pending) > 0 {
		b, _ := json.Marshal(pending)
		fmt.Fprintf(w, "event: pending\ndata: %s\n\n", b)
	}
	flusher.Flush()

	ch := a.hub.subscribe(uid)
	defer a.hub.unsubscribe(uid, ch)

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-ch:
			var ev Event
			if err := json.Unmarshal(b, &ev); err != nil {
				continue
			}
			if !a.store.memberOf(uid, ev.ChatID) {
				continue
			}
			writeEvent(ev)
			flusher.Flush()
		}
	}
}

func (a *api) handleMessageAction(w http.ResponseWriter, r *http.Request) {
	// /api/messages/{id}/{action}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/messages/"), "/")
	if len(parts) != 2 {
		httpError(w, 400, "chemin invalide")
		return
	}
	msgID, action := parts[0], parts[1]

	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}
	uid, _ := body["userId"].(string)
	if uid == "" {
		httpError(w, 400, "userId requis")
		return
	}
	if _, ok := a.store.userByID(uid); !ok {
		httpError(w, 404, "utilisateur inconnu")
		return
	}
	m, exists := a.store.messageByID(msgID)
	if !exists {
		httpError(w, 404, "message introuvable")
		return
	}
	chat, _ := a.store.chatByID(m.ChatID)
	if !a.store.memberOf(uid, m.ChatID) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}

	switch action {
	case "react":
		emoji, _ := body["emoji"].(string)
		if emoji == "" {
			httpError(w, 400, "emoji requis")
			return
		}
		reactions, ok := a.store.toggleReaction(msgID, uid, emoji)
		if !ok {
			httpError(w, 404, "message introuvable")
			return
		}
		a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "react", ChatID: m.ChatID, Data: mustJSON(map[string]any{"id": msgID, "reactions": reactions})})
		wJSON(w, 200, map[string]any{"id": msgID, "reactions": reactions})

	case "edit":
		if m.SenderID != uid {
			httpError(w, 403, "seul l'expéditeur peut modifier")
			return
		}
		text, _ := body["text"].(string)
		if strings.TrimSpace(text) == "" {
			httpError(w, 400, "text requis")
			return
		}
		updated, ok := a.store.editMessage(msgID, uid, text)
		if !ok {
			httpError(w, 404, "message introuvable")
			return
		}
		a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "edit", ChatID: m.ChatID, Data: mustJSON(updated)})
		wJSON(w, 200, updated)

	case "delete":
		mode, _ := body["mode"].(string)
		if mode == "" {
			mode = "me"
		}
		if mode == "all" && m.SenderID != uid {
			httpError(w, 403, "seul l'expéditeur peut supprimer pour tous")
			return
		}
		updated, ok := a.store.deleteMessage(msgID, uid, mode)
		if !ok {
			httpError(w, 404, "message introuvable")
			return
		}
		a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "delete", ChatID: m.ChatID, Data: mustJSON(map[string]any{"id": msgID, "deleted": updated.Deleted, "deletedFor": updated.DeletedFor, "userId": uid})})
		wJSON(w, 200, updated)

	case "vote":
		oi, _ := body["optionIndex"].(float64)
		updated, ok := a.store.votePoll(msgID, uid, int(oi))
		if !ok {
			httpError(w, 400, "sondage invalide")
			return
		}
		a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "vote", ChatID: m.ChatID, Data: mustJSON(map[string]any{"id": msgID, "media": updated.Media})})
		wJSON(w, 200, map[string]any{"id": msgID, "media": updated.Media})

	default:
		httpError(w, 404, "action inconnue")
	}
}
