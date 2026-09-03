package main

import (
	"encoding/json"
	"fmt"
	"math"
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
			// Réglages personnels uniquement (voir scopedSettings).
			c = scopedSettings(c, uid)
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

// handleNotifDefaults lit/écrit les défauts de notification globaux de
// l'utilisateur (toutes les conversations sans préférence propre).
// GET → prefs ; POST corps vide → remise aux défauts de l'app.
func (a *api) handleNotifDefaults(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	switch r.Method {
	case http.MethodGet:
		wJSON(w, 200, a.store.notifDefaultsFor(uid))
	case http.MethodPost:
		var prefs NotifPrefs
		if err := readJSON(r, &prefs); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
		a.store.SetNotifDefaults(uid, prefs)
		wJSON(w, 200, prefs)
	default:
		httpError(w, 405, "méthode non supportée")
	}
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

// ---------- App shell (Discussions + Appels) ----------

// handleShell aggregates everything the app needs on load.
func (a *api) handleShell(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	chats := a.store.chatsFor(uid)
	for i := range chats {
		chats[i] = scopedSettings(chats[i], uid)
	}
	wJSON(w, 200, map[string]any{
		"users":          a.store.state.Users,
		"chats":          chats,
		"calls":          a.store.state.Calls,
		"scheduledCalls": a.store.scheduledCallsFor(uid),
		"notifDefaults":  a.store.notifDefaultsFor(uid),
	})
}

// scopedSettings ne conserve dans le chat que les réglages personnels du
// demandeur (sourdine, préférences de notification) — ceux des autres
// membres ne le concernent pas et ne doivent pas lui être sérialisés.
func scopedSettings(c Chat, uid string) Chat {
	if c.Mutes != nil {
		if u, ok := c.Mutes[uid]; ok {
			c.Mutes = map[string]int64{uid: u}
		} else {
			c.Mutes = nil
		}
	}
	if c.Notifs != nil {
		if p, ok := c.Notifs[uid]; ok {
			c.Notifs = map[string]NotifPrefs{uid: p}
		} else {
			c.Notifs = nil
		}
	}
	return c
}

// handleContactMatch matcht Geräte-Kontakte (Namen + Telefonnummern) gegen
// registrierte Nutzer. Das Telefon hilft beim Finden — angerufen wird in-app.
func (a *api) handleContactMatch(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var body struct {
		Contacts []struct {
			Name   string   `json:"name"`
			Phones []string `json:"phones"`
		} `json:"contacts"`
	}
	if err := readJSON(r, &body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}

	normalize := func(p string) string {
		digits := strings.Map(func(r rune) rune {
			if r >= '0' && r <= '9' {
				return r
			}
			return -1
		}, p)
		if len(digits) > 9 {
			digits = digits[len(digits)-9:] // letzte 9 Ziffern = nationale Nummer
		}
		return digits
	}

	byPhone := map[string]*User{}
	byName := map[string]*User{}
	for i := range a.store.state.Users {
		u := &a.store.state.Users[i]
		if u.Phone != "" {
			byPhone[normalize(u.Phone)] = u
		}
		byName[strings.ToLower(u.Name)] = u
	}

	type match struct {
		Name     string   `json:"name"`
		Phones   []string `json:"phones,omitempty"`
		UserID   string   `json:"userId,omitempty"`
		UserName string   `json:"userName,omitempty"`
		Via      string   `json:"via,omitempty"` // phone | name
	}
	out := []match{}
	for _, c := range body.Contacts {
		m := match{Name: c.Name, Phones: c.Phones}
		for _, p := range c.Phones {
			if u, ok := byPhone[normalize(p)]; ok {
				m.UserID, m.UserName, m.Via = u.ID, u.Name, "phone"
				break
			}
		}
		if m.UserID == "" {
			if u, ok := byName[strings.ToLower(strings.TrimSpace(c.Name))]; ok {
				m.UserID, m.UserName, m.Via = u.ID, u.Name, "name"
			}
		}
		out = append(out, m)
	}
	_ = uid
	wJSON(w, 200, map[string]any{"matches": out})
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

// ---------- Appels planifiés ----------

func (a *api) handleScheduledCalls(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	switch r.Method {
	case http.MethodGet:
		wJSON(w, 200, a.store.scheduledCallsFor(uid))
	case http.MethodPost:
		var body struct {
			Title       string   `json:"title"`
			ScheduledAt int64    `json:"scheduledAt"`
			Kind        string   `json:"kind"`
			MemberIDs   []string `json:"memberIds"`
			ChatID      string   `json:"chatId"`
			Reminder    bool     `json:"reminder"`
		}
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
		if strings.TrimSpace(body.Title) == "" {
			httpError(w, 400, "title requis")
			return
		}
		if body.ScheduledAt == 0 {
			body.ScheduledAt = time.Now().Add(24 * time.Hour).UnixMilli()
		}
		kind := body.Kind
		if kind != "video" {
			kind = "audio"
		}
		sc := a.store.addScheduledCall(ScheduledCall{
			Title:       strings.TrimSpace(body.Title),
			UserID:      uid,
			MemberIDs:   body.MemberIDs,
			ChatID:      body.ChatID,
			ScheduledAt: body.ScheduledAt,
			Kind:        kind,
			Reminder:    body.Reminder,
		})
		a.broadcastShell(uid)
		wJSON(w, 201, sc)
	case http.MethodPatch:
		var body struct {
			ID string `json:"id"`
		}
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide")
			return
		}
		updated, ok := a.store.toggleScheduledReminder(body.ID)
		if !ok {
			httpError(w, 404, "appel planifié introuvable")
			return
		}
		wJSON(w, 200, updated)
	case http.MethodDelete:
		id := strings.TrimPrefix(r.URL.Path, "/api/scheduled-calls/")
		if id == "" {
			httpError(w, 400, "id requis")
			return
		}
		if !a.store.deleteScheduledCall(id) {
			httpError(w, 404, "appel planifié introuvable")
			return
		}
		wJSON(w, 200, map[string]bool{"deleted": true})
	default:
		httpError(w, 405, "méthode non supportée")
	}
}

// broadcastShell publie un event "shell" (UI : rafraîchit les données agrégées).
func (a *api) broadcastShell(uid string) {
	a.hub.broadcastToUsers(a.store.userList(), Event{Type: "shell", ChatID: "", Data: mustJSON(map[string]string{"userId": uid})})
}

// ---------- Appels (signalisation temps réel) ----------

func (a *api) handleCallInitiate(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var body struct {
		ChatID string `json:"chatId"`
		Kind   string `json:"kind"` // audio | video
	}
	if err := readJSON(r, &body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}
	if body.ChatID == "" {
		httpError(w, 400, "chatId requis")
		return
	}
	chat, ok := a.store.chatByID(body.ChatID)
	if !ok || !inSlice(chat.MemberIDs, uid) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}
	if body.Kind == "" {
		body.Kind = "audio"
	}
	callerName := uid
	if u, ok := a.store.userByID(uid); ok {
		callerName = u.Name
	}
	c := a.store.createCall(chat.ID, uid, callerName, body.Kind)
	// Diffusion à tous les membres (sauf l'appelant) : événement "call" temps réel.
	members := []string{}
	for _, m := range chat.MemberIDs {
		if m != uid {
			members = append(members, m)
		}
	}
	a.hub.broadcastToUsers(members, Event{Type: "call", ChatID: chat.ID, Data: mustJSON(c)})
	wJSON(w, 201, c)
}

func (a *api) handleCallRespond(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CallID string `json:"callId"`
		Status string `json:"status"` // accepted | declined
	}
	if err := readJSON(r, &body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}
	if body.Status != "accepted" && body.Status != "declined" && body.Status != "missed" && body.Status != "ended" {
		httpError(w, 400, "status doit être accepted, declined, missed ou ended")
		return
	}
	updated, ok := a.store.respondCall(body.CallID, body.Status)
	if !ok {
		httpError(w, 404, "appel introuvable")
		return
	}
	chat, _ := a.store.chatByID(updated.ChatID)
	if body.Status == "missed" {
		name := updated.CallerName
		isGroup := chat != nil && chat.Type == "group"
		if isGroup {
			name = chat.Name
		}
		a.store.addCallLog(CallLog{
			ID:        newID("cl"),
			Type:      updated.Kind,
			UserID:    updated.CallerID,
			Name:      name,
			Group:     isGroup,
			Direction: "missed",
			IsVideo:   updated.Kind == "video",
			CreatedAt: time.Now().UnixMilli(),
		})
	}
	a.hub.broadcastToUsers(chat.MemberIDs, Event{Type: "call_respond", ChatID: updated.ChatID, Data: mustJSON(updated)})
	wJSON(w, 200, updated)
} // handleCallSignal relaie la signalisation WebRTC (offer/answer/ICE) entre
// les participants d'un appel existant via le hub temps réel.
func (a *api) handleCallSignal(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var body struct {
		CallID  string          `json:"callId"`
		Kind    string          `json:"kind"` // offer | answer | ice
		Payload json.RawMessage `json:"payload"`
	}
	if err := readJSON(r, &body); err != nil {
		httpError(w, 400, "corps invalide: "+err.Error())
		return
	}
	c, ok := a.store.callByID(body.CallID)
	if !ok {
		httpError(w, 404, "appel introuvable")
		return
	}
	chat, ok := a.store.chatByID(c.ChatID)
	if !ok || !inSlice(chat.MemberIDs, uid) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}
	if body.Kind != "offer" && body.Kind != "answer" && body.Kind != "ice" {
		httpError(w, 400, "kind doit être offer, answer ou ice")
		return
	}
	targets := []string{}
	for _, m := range chat.MemberIDs {
		if m != uid {
			targets = append(targets, m)
		}
	}
	a.hub.broadcastToUsers(targets, Event{Type: "call_signal", ChatID: c.ChatID, Data: mustJSON(map[string]any{
		"callId":  body.CallID,
		"kind":    body.Kind,
		"from":    uid,
		"payload": body.Payload,
	})})
	wJSON(w, 200, map[string]bool{"relayed": true})
}

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
		// Sourdine active sur cette conversation : pas d'indicateur de saisie.
		if ev.Type == "typing" && a.store.mutedForUser(ev.ChatID, uid) {
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

	case "star":
		starred, ok := a.store.toggleStar(msgID, uid)
		if !ok {
			httpError(w, 404, "message introuvable")
			return
		}
		// Favori personnel : pas de broadcast (les autres ne sont pas concernés).
		wJSON(w, 200, map[string]any{"id": msgID, "starredBy": starred})

	default:
		httpError(w, 404, "action inconnue")
	}
}

// handleChatAction route /api/chats/{id}/... : messages vers le handler
// existant, {id}/archive vers l'action d'archivage.
func (a *api) handleChatAction(w http.ResponseWriter, r *http.Request) {
	if strings.HasSuffix(r.URL.Path, "/messages") {
		a.handleMessages(w, r)
		return
	}
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/chats/"), "/")
	if len(parts) != 2 {
		httpError(w, 404, "action inconnue")
		return
	}
	chatID, action := parts[0], parts[1]
	if !a.store.memberOf(uid, chatID) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}
	var body struct {
		Archived      bool   `json:"archived"`
		Pinned        bool   `json:"pinned"`
		Until         int64  `json:"until"`    // mute : expiration (epoch ms)
		Duration      string `json:"duration"` // mute : 8h | 1w | always
		NotifPriority string `json:"priority"` // notifs : low | default | high
		NotifSound    *bool  `json:"sound"`    // notifs : son on/off
		NotifPreview  *bool  `json:"preview"`  // notifs : aperçu on/off
	}
	// delete n'a pas de corps : tout ce qui compte est l'utilisateur.
	if action != "delete" {
		if err := readJSON(r, &body); err != nil {
			httpError(w, 400, "corps invalide: "+err.Error())
			return
		}
	}
	switch action {
	case "archive":
		if !a.store.setArchived(chatID, uid, body.Archived) {
			httpError(w, 404, "conversation introuvable")
			return
		}
		wJSON(w, 200, map[string]any{"id": chatID, "archived": body.Archived})
	case "pin":
		if !a.store.setPinned(chatID, uid, body.Pinned) {
			httpError(w, 404, "conversation introuvable")
			return
		}
		// Épinglage personnel : pas de broadcast.
		wJSON(w, 200, map[string]any{"id": chatID, "pinned": body.Pinned})
	case "delete":
		// Suppression pour moi : la conversation disparaît de ma liste,
		// l'historique et les autres membres sont conservés.
		if !a.store.deleteChatFor(chatID, uid) {
			httpError(w, 404, "conversation introuvable")
			return
		}
		wJSON(w, 200, map[string]any{"id": chatID, "deletedFor": uid})
	case "mute":
		// Sourdine personnelle avec expiration. Accepte soit une durée
		// symbolique (8h | 1w | always), soit un epoch ms direct (`until`).
		until := body.Until
		if until == 0 {
			switch body.Duration {
			case "8h":
				until = time.Now().Add(8 * time.Hour).UnixMilli()
			case "1w":
				until = time.Now().Add(7 * 24 * time.Hour).UnixMilli()
			case "always":
				until = math.MaxInt64
			case "off":
				// until reste 0 : SetMute supprime l'entrée (démute).
			default:
				httpError(w, 400, "duration requise (8h | 1w | always | off)")
				return
			}
		}
		if !a.store.SetMute(chatID, uid, until) {
			httpError(w, 404, "conversation introuvable")
			return
		}
		// Sourdine personnelle : pas de broadcast.
		wJSON(w, 200, map[string]any{"id": chatID, "until": until})
	case "notifs":
		// Préférences de notification personnelles (priorité, son, aperçu).
		// Corps vide / champs absents = remise aux défauts de l'app.
		prefs := NotifPrefs{Priority: body.NotifPriority}
		if body.NotifSound != nil {
			s := *body.NotifSound
			prefs.Sound = &s
		}
		if body.NotifPreview != nil {
			p := *body.NotifPreview
			prefs.Preview = &p
		}
		if !a.store.SetNotifs(chatID, uid, prefs) {
			httpError(w, 404, "conversation introuvable")
			return
		}
		wJSON(w, 200, map[string]any{"id": chatID, "notifs": prefs})
	default:
		httpError(w, 404, "action inconnue")
	}
}

// handleTyping relaie l'indicateur de saisie (éphémère, sans log de replay).
func (a *api) handleTyping(w http.ResponseWriter, r *http.Request) {
	uid, ok := a.userOrError(w, r)
	if !ok {
		return
	}
	var body struct {
		ChatID string `json:"chatId"`
	}
	if err := readJSON(r, &body); err != nil || body.ChatID == "" {
		httpError(w, 400, "chatId requis")
		return
	}
	if !a.store.memberOf(uid, body.ChatID) {
		httpError(w, 403, "pas membre de cette conversation")
		return
	}
	name := uid
	if u, ok := a.store.userByID(uid); ok {
		name = u.Name
	}
	chat, ok := a.store.chatByID(body.ChatID)
	if !ok {
		httpError(w, 404, "conversation introuvable")
		return
	}
	targets := []string{}
	for _, m := range chat.MemberIDs {
		if m != uid {
			// Sourdine active : pas d'indicateur de saisie.
			if mutedUntil(chat.Mutes, m) == 0 {
				targets = append(targets, m)
			}
		}
	}
	a.hub.broadcastToUsers(targets, Event{Type: "typing", ChatID: body.ChatID, Data: mustJSON(map[string]string{"chatId": body.ChatID, "userId": uid, "name": name})})
	wJSON(w, 200, map[string]bool{"ok": true})
}
