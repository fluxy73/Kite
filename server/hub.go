package main

import (
	"encoding/json"
	"sync"
)

const eventLogCap = 1000

// Event is a realtime event broadcast to chat members via SSE.
type Event struct {
	ID     int64           `json:"id"`
	Type   string          `json:"type"` // message, react, edit, delete, vote, read
	ChatID string          `json:"chatId"`
	Data   json.RawMessage `json:"data"`
}

// Hub tracks active SSE connections per user and keeps a replay log.
type Hub struct {
	mu    sync.Mutex
	subs  map[string]map[chan []byte]struct{}
	log   []Event
	seq   int64
	conns map[string]int
}

func NewHub() *Hub {
	return &Hub{
		subs:  map[string]map[chan []byte]struct{}{},
		conns: map[string]int{},
	}
}

// isOnline reports whether the user has at least one active SSE connection.
func (h *Hub) isOnline(userID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.conns[userID] > 0
}

// broadcastToUsers delivers an event to every connected member and logs it for replay.
func (h *Hub) broadcastToUsers(userIDs []string, ev Event) {
	h.mu.Lock()
	h.seq++
	ev.ID = h.seq
	b, _ := json.Marshal(ev)
	h.log = append(h.log, ev)
	if len(h.log) > eventLogCap {
		h.log = h.log[len(h.log)-eventLogCap:]
	}
	chans := map[chan []byte]struct{}{}
	for _, uid := range userIDs {
		for c := range h.subs[uid] {
			chans[c] = struct{}{}
		}
	}
	h.mu.Unlock()
	for c := range chans {
		select {
		case c <- b:
		default:
		}
	}
}

// replay returns the events with ID strictly greater than since.
func (h *Hub) replay(since int64) []Event {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := []Event{}
	for _, ev := range h.log {
		if ev.ID > since {
			out = append(out, ev)
		}
	}
	return out
}

// subscribe registers a channel for live events and returns it.
func (h *Hub) subscribe(userID string) chan []byte {
	ch := make(chan []byte, 64)
	h.mu.Lock()
	if h.subs[userID] == nil {
		h.subs[userID] = map[chan []byte]struct{}{}
	}
	h.subs[userID][ch] = struct{}{}
	h.conns[userID]++
	h.mu.Unlock()
	return ch
}

// unsubscribe removes a channel and decrements the connection counter.
func (h *Hub) unsubscribe(userID string, ch chan []byte) {
	h.mu.Lock()
	delete(h.subs[userID], ch)
	h.conns[userID]--
	if h.conns[userID] <= 0 {
		delete(h.conns, userID)
	}
	h.mu.Unlock()
}
