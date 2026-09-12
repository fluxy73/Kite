package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// ---- Harness : vrai serveur (store + hub + mux), deux clients WS ----

type e2eServer struct {
	t   *testing.T
	ts  *httptest.Server
	base string // http://127.0.0.1:port
}

func newE2E(t *testing.T) *e2eServer {
	t.Helper()
	dir := t.TempDir()
	store, err := NewStore(dir + "/kite.json")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	a := &api{store: store, hub: NewHub(), meID: "u-julien"}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		wJSON(w, 200, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/users", cors(a.handleUsers))
	mux.HandleFunc("/api/chats", cors(a.handleChats))
	mux.HandleFunc("/api/chats/", cors(a.handleChatAction))
	mux.HandleFunc("/api/messages/", cors(a.handleMessageAction))
	mux.HandleFunc("/api/typing", cors(a.handleTyping))
	mux.HandleFunc("/api/ws", cors(a.handleWS))
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	base := strings.TrimPrefix(ts.URL, "http://")
	return &e2eServer{t: t, ts: ts, base: base}
}

func (e *e2eServer) getJSON(path string) map[string]any {
	e.t.Helper()
	resp, err := http.Get("http://" + e.base + path)
	if err != nil {
		e.t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		e.t.Fatalf("GET %s decode: %v", path, err)
	}
	return out
}

func (e *e2eServer) postJSON(path string, body map[string]any) (int, map[string]any) {
	e.t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post("http://"+e.base+path, "application/json", strings.NewReader(string(b)))
	if err != nil {
		e.t.Fatalf("POST %s: %v", path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// dialWS connecte un client WebSocket authentifié par userId.
func (e *e2eServer) dialWS(userID string) *wsClient {
	e.t.Helper()
	u := url.URL{Scheme: "ws", Host: e.base, Path: "/api/ws", RawQuery: "userId=" + url.QueryEscape(userID)}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, u.String(), nil)
	if err != nil {
		e.t.Fatalf("dial WS %s: %v", userID, err)
	}
	c := &wsClient{conn: conn}
	t := e.t
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	return c
}

type wsClient struct {
	conn *websocket.Conn
}

type wsEvent struct {
	ID     int64           `json:"id"`
	Type   string          `json:"type"`
	ChatID string          `json:"chatId"`
	Data   json.RawMessage `json:"data"`
}

// nextEvent lit l'événement suivant (filtré par type si non vide) et le
// décode : data est un objet JSON inline produit par le serveur.
func (c *wsClient) nextEvent(t *testing.T, wantType string, timeout time.Duration) wsEvent {
	t.Helper()
	deadline := time.Now().Add(timeout)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		if time.Now().After(deadline) {
			t.Fatalf("timeout (%v) en attendant un événement %q", timeout, wantType)
		}
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			t.Fatalf("lecture WS: %v", err)
		}
		var ev wsEvent
		if err := json.Unmarshal(data, &ev); err != nil {
			t.Fatalf("événement invalide: %v (%s)", err, data)
		}
		if wantType == "" || ev.Type == wantType {
			return ev
		}
	}
}

// ---- Scénarios ----

// seedDM retourne l'id d'une DM fraîche entre emma et lucas (POST /api/chats,
// userId en query comme le client réel).
func (e *e2eServer) seedDM() string {
	e.t.Helper()
	code, out := e.postJSON("/api/chats?userId=u-emma", map[string]any{
		"type":      "dm",
		"memberIds": []string{"u-lucas"},
	})
	if code != 201 && code != 200 {
		e.t.Fatalf("createChat: %d %v", code, out)
	}
	return out["id"].(string)
}

// 1. A envoie -> B reçoit via push WS et le message est lisible via GET.
func TestE2EMessagePush(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()

	b := e.dialWS("u-lucas")

	code, sent := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": "coucou B", "senderId": "u-emma"})
	if code != 201 {
		t.Fatalf("send: %d %v", code, sent)
	}

	// Push temps réel côté B.
	ev := b.nextEvent(t, "message", 5*time.Second)
	if ev.ChatID != chat {
		t.Fatalf("chatId inattendu: %v", ev.ChatID)
	}
	var msg map[string]any
	if err := json.Unmarshal(ev.Data, &msg); err != nil {
		t.Fatalf("data: %v", err)
	}
	if msg["text"] != "coucou B" || msg["senderId"] != "u-emma" {
		t.Fatalf("message push incorrect: %v", msg)
	}

	// Visible par B via l'API REST (liste de messages).
	resp, err := http.Get(fmt.Sprintf("http://%s/api/chats/%s/messages?userId=u-lucas", e.base, chat))
	if err != nil {
		t.Fatalf("GET messages: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(raw), "coucou B") {
		t.Fatalf("message non visible via GET: %s", raw)
	}
}

// 2. Réaction B -> A : le point de code emoji exact survit au serveur.
func TestE2EReactionEmojiIntact(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()

	b := e.dialWS("u-lucas")
	a := e.dialWS("u-emma")

	_, sent := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": "à réagir", "senderId": "u-emma"})
	msgID := sent["id"].(string)
	b.nextEvent(t, "message", 5*time.Second) // B a bien vu le message

	const emoji = "🙏🏽" // U+1F64F U+1F3FD : multi-octets, hors ASCII
	code, out := e.postJSON(fmt.Sprintf("/api/messages/%s/react", msgID),
		map[string]any{"userId": "u-lucas", "emoji": emoji})
	if code != 200 {
		t.Fatalf("react: %d %v", code, out)
	}	// Push WS côté A : la réaction arrive avec le même point de code.
	ev := a.nextEvent(t, "react", 5*time.Second)
	var data struct {
		ID        string           `json:"id"`
		Reactions map[string][]any `json:"reactions"`
	}
	if err := json.Unmarshal(ev.Data, &data); err != nil {
		t.Fatalf("react data: %v", err)
	}
	if data.ID != msgID {
		t.Fatalf("id inattendu: %s", data.ID)
	}
	users, ok := data.Reactions[emoji]
	if !ok {
		t.Fatalf("emoji %q (U+%04X chaque rune) absent des réactions: %v", emoji, []rune(emoji), data.Reactions)
	}
	if len(users) != 1 || users[0] != "u-lucas" {
		t.Fatalf("réacteurs inattendus: %v", users)
	}

	// Toggle off -> la clé emoji disparaît (round-trip complet).
	code, out2 := e.postJSON(fmt.Sprintf("/api/messages/%s/react", msgID),
		map[string]any{"userId": "u-lucas", "emoji": emoji})
	if code != 200 {
		t.Fatalf("react off: %d %v", code, out2)
	}
	ev2 := a.nextEvent(t, "react", 5*time.Second)
	var data2 map[string]any
	_ = json.Unmarshal(ev2.Data, &data2)
	if r := data2["reactions"].(map[string]any); len(r) != 0 {
		t.Fatalf("réactions après toggle off: %v", r)
	}
}

// 3. Indicateur de saisie et accusés de lecture diffusés à l'autre partie.
func TestE2ETypingAndReadReceipts(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()

	a := e.dialWS("u-emma")
	b := e.dialWS("u-lucas")

	// A tape -> B voit l'indicateur avec le nom résolu.
	code, out := e.postJSON("/api/typing?userId=u-emma",
		map[string]any{"chatId": chat})
	if code != 200 {
		t.Fatalf("typing: %d %v", code, out)
	}
	ev := b.nextEvent(t, "typing", 5*time.Second)
	var data map[string]string
	if err := json.Unmarshal(ev.Data, &data); err != nil {
		t.Fatalf("typing data: %v", err)
	}
	if data["userId"] != "u-emma" || data["name"] != "Emma Bernard" {
		t.Fatalf("typing incorrect: %v", data)
	}

	// A envoie un message, B le lit -> A reçoit l'accusé "read".
	_, sent := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": "à lire", "senderId": "u-emma"})
	if sent["id"] == nil {
		t.Fatalf("send: %v", sent)
	}
	a.nextEvent(t, "", 5*time.Second) // écho du message à l'expéditeur (type quelconque)
	b.nextEvent(t, "message", 5*time.Second)

	if _, err := http.Get(fmt.Sprintf("http://%s/api/chats/%s/messages?userId=u-lucas", e.base, chat)); err != nil {
		t.Fatalf("fetch (déclenche markRead): %v", err)
	}
	readEv := a.nextEvent(t, "read", 5*time.Second)
	var readData map[string]string
	if err := json.Unmarshal(readEv.Data, &readData); err != nil {
		t.Fatalf("read data: %v", err)
	}
	if readData["userId"] != "u-lucas" || readData["chatId"] != chat {
		t.Fatalf("read incorrect: %v", readData)
	}
}

// 4. B hors-ligne : A envoie -> B se reconnecte -> livraison du pending.
func TestE2EPendingDeliveryOnReconnect(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()

	// B n'est PAS connecté : le message part en pending.
	code, sent := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": "pendant ton absence", "senderId": "u-emma"})
	if code != 201 {
		t.Fatalf("send: %d %v", code, sent)
	}

	// B se connecte : le serveur pousse {"type":"pending"} en premier.
	b := e.dialWS("u-lucas")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := b.conn.Read(ctx)
	if err != nil {
		t.Fatalf("lecture pending: %v", err)
	}
	var ev struct {
		Type string           `json:"type"`
		Data []map[string]any `json:"data"`
	}
	if err := json.Unmarshal(data, &ev); err != nil {
		t.Fatalf("pending invalide: %v (%s)", err, data)
	}
	if ev.Type != "pending" {
		t.Fatalf("premier événement attendu: pending, reçu %q (%s)", ev.Type, data)
	}
	found := false
	for _, m := range ev.Data {
		if m["text"] == "pendant ton absence" {
			found = true
		}
	}
	if !found {
		t.Fatalf("message en attente absent du push pending: %s", data)
	}
}
