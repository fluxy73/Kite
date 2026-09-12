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

// E2E temps réel : store + hub + mux réels via httptest, deux clients
// WebSocket natifs (coder/websocket), aucune simulation.

type e2eServer struct {
	t    *testing.T
	base string // host:port du serveur de test
}

func newE2E(t *testing.T) *e2eServer {
	t.Helper()
	store, err := NewStore(t.TempDir() + "/kite.json")
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	a := &api{store: store, hub: NewHub(), meID: "u-julien"}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chats", cors(a.handleChats))
	mux.HandleFunc("/api/chats/", cors(a.handleChatAction))
	mux.HandleFunc("/api/messages/", cors(a.handleMessageAction))
	mux.HandleFunc("/api/typing", cors(a.handleTyping))
	mux.HandleFunc("/api/ws", cors(a.handleWS))
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return &e2eServer{t: t, base: strings.TrimPrefix(ts.URL, "http://")}
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

func (e *e2eServer) send(chat, text string) {
	e.t.Helper()
	code, out := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": text, "senderId": "u-emma"})
	if code != 201 {
		e.t.Fatalf("send: %d %v", code, out)
	}
}

func (e *e2eServer) dialWS(userID string) *websocket.Conn {
	e.t.Helper()
	u := url.URL{Scheme: "ws", Host: e.base, Path: "/api/ws", RawQuery: "userId=" + userID}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, u.String(), nil)
	if err != nil {
		e.t.Fatalf("dial WS %s: %v", userID, err)
	}
	t := e.t
	t.Cleanup(func() { _ = conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

type wsEvent struct {
	Type   string          `json:"type"`
	ChatID string          `json:"chatId"`
	Data   json.RawMessage `json:"data"`
}

// nextEvent lit l'événement suivant (filtré par type si non vide).
func nextEvent(t *testing.T, c *websocket.Conn, wantType string, timeout time.Duration) wsEvent {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	for {
		_, data, err := c.Read(ctx)
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

// seedDM crée une DM emma–lucas et retourne son id (POST /api/chats,
// userId en query comme le client réel).
func (e *e2eServer) seedDM() string {
	e.t.Helper()
	code, out := e.postJSON("/api/chats?userId=u-emma", map[string]any{
		"type":      "dm",
		"memberIds": []string{"u-lucas"},
	})
	if code != 201 {
		e.t.Fatalf("createChat: %d %v", code, out)
	}
	return out["id"].(string)
}

// 1. A envoie -> B reçoit via push WS et le message est visible via GET.
func TestE2EMessagePush(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()
	b := e.dialWS("u-lucas")

	e.send(chat, "coucou B")

	ev := nextEvent(t, b, "message", 5*time.Second)
	if ev.ChatID != chat || !strings.Contains(string(ev.Data), "coucou B") {
		t.Fatalf("push incorrect: %+v %s", ev.ChatID, ev.Data)
	}
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
	a := e.dialWS("u-emma")
	b := e.dialWS("u-lucas")

	_, sent := e.postJSON(fmt.Sprintf("/api/chats/%s/messages?userId=u-emma", chat),
		map[string]any{"type": "text", "text": "à réagir", "senderId": "u-emma"})
	msgID := sent["id"].(string)
	nextEvent(t, b, "message", 5*time.Second)

	const emoji = "🙏🏽" // U+1F64F U+1F3FD : multi-octets, hors ASCII
	code, out := e.postJSON(fmt.Sprintf("/api/messages/%s/react", msgID),
		map[string]any{"userId": "u-lucas", "emoji": emoji})
	if code != 200 {
		t.Fatalf("react: %d %v", code, out)
	}

	ev := nextEvent(t, a, "react", 5*time.Second)
	var data struct {
		ID        string           `json:"id"`
		Reactions map[string][]any `json:"reactions"`
	}
	if err := json.Unmarshal(ev.Data, &data); err != nil {
		t.Fatalf("react data: %v", err)
	}
	users, ok := data.Reactions[emoji]
	if !ok {
		t.Fatalf("emoji %q absent des réactions: %v", emoji, data.Reactions)
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
	ev2 := nextEvent(t, a, "react", 5*time.Second)
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
	code, out := e.postJSON("/api/typing?userId=u-emma", map[string]any{"chatId": chat})
	if code != 200 {
		t.Fatalf("typing: %d %v", code, out)
	}
	ev := nextEvent(t, b, "typing", 5*time.Second)
	var typing map[string]string
	if err := json.Unmarshal(ev.Data, &typing); err != nil {
		t.Fatalf("typing data: %v", err)
	}
	if typing["userId"] != "u-emma" || typing["name"] != "Emma Bernard" {
		t.Fatalf("typing incorrect: %v", typing)
	}

	// A envoie, B lit -> A reçoit l'accusé "read".
	e.send(chat, "à lire")
	nextEvent(t, a, "message", 5*time.Second) // écho à l'expéditeur
	nextEvent(t, b, "message", 5*time.Second)

	if _, err := http.Get(fmt.Sprintf("http://%s/api/chats/%s/messages?userId=u-lucas", e.base, chat)); err != nil {
		t.Fatalf("fetch (déclenche markRead): %v", err)
	}
	readEv := nextEvent(t, a, "read", 5*time.Second)
	var read map[string]string
	if err := json.Unmarshal(readEv.Data, &read); err != nil {
		t.Fatalf("read data: %v", err)
	}
	if read["userId"] != "u-lucas" || read["chatId"] != chat {
		t.Fatalf("read incorrect: %v", read)
	}
}

// 4. B hors-ligne : A envoie -> B se reconnecte -> livraison du pending.
func TestE2EPendingDeliveryOnReconnect(t *testing.T) {
	e := newE2E(t)
	chat := e.seedDM()

	// B n'est PAS connecté : le message part en pending.
	e.send(chat, "pendant ton absence")

	// B se connecte : le serveur pousse {"type":"pending"} en premier.
	b := e.dialWS("u-lucas")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := b.Read(ctx)
	if err != nil {
		t.Fatalf("lecture pending: %v", err)
	}
	var ev wsEvent
	if err := json.Unmarshal(data, &ev); err != nil {
		t.Fatalf("pending invalide: %v (%s)", err, data)
	}
	if ev.Type != "pending" || !strings.Contains(string(ev.Data), "pendant ton absence") {
		t.Fatalf("pending incorrect: %s", data)
	}
}
