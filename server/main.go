package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := envOr("KITE_ADDR", ":8080")
	dataPath := envOr("KITE_DATA", "data/kite.json")

	store, err := NewStore(dataPath)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	hub := NewHub()
	a := &api{store: store, hub: hub, meID: "u-julien"}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", cors(func(w http.ResponseWriter, r *http.Request) {
		wJSON(w, 200, map[string]any{"ok": true, "service": "kite-server", "time": time.Now().UnixMilli()})
	}))
	mux.HandleFunc("/api/users", cors(a.handleUsers))
	mux.HandleFunc("/api/chats", cors(a.handleChats))
	mux.HandleFunc("/api/chats/", cors(a.handleChatAction)) // {id}/archive ; /api/chats/{id}/messages routé en interne
	mux.HandleFunc("/api/messages/", cors(a.handleMessageAction))
	mux.HandleFunc("/api/events", cors(a.handleEvents))
	mux.HandleFunc("/api/ws", cors(a.handleWS))
	mux.HandleFunc("/api/shell", cors(a.handleShell))
	mux.HandleFunc("/api/calls/log", cors(a.handleCallLog))
	mux.HandleFunc("/api/calls/initiate", cors(a.handleCallInitiate))
	mux.HandleFunc("/api/calls/signal", cors(a.handleCallSignal))
	mux.HandleFunc("/api/contacts/match", cors(a.handleContactMatch))
	mux.HandleFunc("/api/calls/respond", cors(a.handleCallRespond))
	mux.HandleFunc("/api/typing", cors(a.handleTyping))
	mux.HandleFunc("/api/notif-defaults", cors(a.handleNotifDefaults))
	mux.HandleFunc("/api/scheduled-messages", cors(a.handleScheduledMessages))
	mux.HandleFunc("/api/scheduled-messages/", cors(a.handleScheduledMessages))
	mux.HandleFunc("/api/scheduled-calls", cors(a.handleScheduledCalls))
	mux.HandleFunc("/api/scheduled-calls/", cors(a.handleScheduledCalls))

	// Dispatch automatique des messages programmés, toutes les 15 s.
	go func() {
		for range time.Tick(15 * time.Second) {
			a.dispatchScheduledMessages()
		}
	}()

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("Kite server — écoute sur http://localhost%s", addr)
	log.Printf("Données : %s (seed automatique au premier lancement)", dataPath)
	log.Printf("Endpoints : /api/health · /api/users · /api/chats · /api/chats/{id}/messages · /api/messages/{id}/{react|edit|delete|vote} · /api/shell  · /api/calls/log  · /api/calls/signal  · /api/contacts/match · /api/events (SSE) · /api/ws (WebSocket)")
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("serveur: %v", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
