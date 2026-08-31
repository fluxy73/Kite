package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// ---------- Models ----------

type User struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Community is a container that groups several chats (groups).
type Community struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	GroupIDs    []string `json:"groupIds"`
	CreatedAt   int64    `json:"createdAt"`
}

// CallLog is a single call entry in the Calls tab.
type CallLog struct {
	ID          string `json:"id"`
	Type        string `json:"type"`   // audio | video
	UserID      string `json:"userId"` // contact (ou groupe)
	Name        string `json:"name"`
	Group       bool   `json:"group"`
	Direction   string `json:"direction"` // incoming | outgoing | missed
	IsVideo     bool   `json:"isVideo"`
	CreatedAt   int64  `json:"createdAt"`
	CompletedAt int64  `json:"completedAt"`
}

// CallRecord tracks an in-flight call (signaling temps réel).
type CallRecord struct {
	ID         string `json:"id"`
	ChatID     string `json:"chatId"`
	CallerID   string `json:"callerId"`
	CallerName string `json:"callerName"`
	Kind       string `json:"kind"`   // audio | video
	Status     string `json:"status"` // ringing | accepted | declined | missed | ended
	CreatedAt  int64  `json:"createdAt"`
	UpdatedAt  int64  `json:"updatedAt"`
}

// ScheduledCall is a call planned for a future date/time (Calls tab).
type ScheduledCall struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	UserID      string   `json:"userId"`      // créateur
	MemberIDs   []string `json:"memberIds"`   // participants
	ChatID      string   `json:"chatId"`      // conversation rattachée ('' = générique)
	ScheduledAt int64    `json:"scheduledAt"` // timestamp de l'échéance
	Kind        string   `json:"kind"`        // audio | video
	Reminder    bool     `json:"reminder"`
	CreatedAt   int64    `json:"createdAt"`
}

type Chat struct {
	ID        string   `json:"id"`
	Type      string   `json:"type"` // dm | group | community
	Name      string   `json:"name"`
	MemberIDs []string `json:"memberIds"`
	AdminIDs  []string `json:"adminIds"`
	CreatedAt int64    `json:"createdAt"`
}

type Message struct {
	ID          string              `json:"id"`
	ChatID      string              `json:"chatId"`
	SenderID    string              `json:"senderId"`
	Type        string              `json:"type"` // text, image, video, document, audio, voice, videonote, gif, sticker, contact, location, poll, event, call, system
	Text        string              `json:"text,omitempty"`
	Media       map[string]any      `json:"media,omitempty"`
	CreatedAt   int64               `json:"createdAt"`
	Edited      bool                `json:"edited,omitempty"`
	Deleted     bool                `json:"deleted,omitempty"`
	DeletedFor  []string            `json:"deletedFor,omitempty"`
	Reactions   map[string][]string `json:"reactions,omitempty"` // emoji -> user ids
	ReplyTo     string              `json:"replyTo,omitempty"`
	ReadBy      []string            `json:"readBy,omitempty"`
	DeliveredTo []string            `json:"deliveredTo,omitempty"`
}

type Pending struct {
	UserID  string  `json:"userId"`
	Message Message `json:"message"`
}

type State struct {
	Users          []User          `json:"users"`
	Chats          []Chat          `json:"chats"`
	Messages       []Message       `json:"messages"`
	Pending        []Pending       `json:"pending"`
	Communities    []Community     `json:"communities"`
	Calls          []CallLog       `json:"calls"`
	CallRecords    []CallRecord    `json:"callRecords"`
	ScheduledCalls []ScheduledCall `json:"scheduledCalls"`
	SeedVersion    int             `json:"seedVersion"`
}

// seedVersion is bumped whenever the shape of seedState() changes, so an
// existing data file is regenerated on the next start.
const seedVersion = 5

// ---------- Store ----------

type Store struct {
	mu    sync.RWMutex
	state State
	path  string
}

func NewStore(path string) (*Store, error) {
	s := &Store{path: path}
	regen := false
	if _, err := os.Stat(path); err == nil {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("lecture %s: %w", path, err)
		}
		if err := json.Unmarshal(b, &s.state); err != nil {
			return nil, fmt.Errorf("json %s: %w", path, err)
		}
		// Forcer la régénération quand le schema du seed évolue.
		regen = s.state.SeedVersion != seedVersion
	} else {
		regen = true
	}
	if regen {
		s.state = seedState()
		s.state.SeedVersion = seedVersion
		if err := s.save(); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *Store) save() error {
	b, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func newID(prefix string) string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return prefix + "-" + hex.EncodeToString(b)
}

func inSlice(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func removeFrom(s []string, v string) []string {
	out := s[:0]
	for _, x := range s {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}

// ---------- Queries ----------

func (s *Store) userByID(id string) (*User, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.Users {
		if s.state.Users[i].ID == id {
			return &s.state.Users[i], true
		}
	}
	return nil, false
}

func (s *Store) chatByID(id string) (*Chat, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.Chats {
		if s.state.Chats[i].ID == id {
			return &s.state.Chats[i], true
		}
	}
	return nil, false
}

func (s *Store) memberOf(userID, chatID string) bool {
	c, ok := s.chatByID(chatID)
	return ok && inSlice(c.MemberIDs, userID)
}

func (s *Store) chatMessages(chatID, userID string) []Message {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []Message{}
	for _, m := range s.state.Messages {
		if m.ChatID != chatID {
			continue
		}
		if m.Deleted || inSlice(m.DeletedFor, userID) {
			continue
		}
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt < out[j].CreatedAt })
	return out
}

func (s *Store) messageByID(id string) (*Message, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.Messages {
		if s.state.Messages[i].ID == id {
			return &s.state.Messages[i], true
		}
	}
	return nil, false
}

func (s *Store) chatsFor(userID string) []Chat {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []Chat{}
	for _, c := range s.state.Chats {
		if inSlice(c.MemberIDs, userID) {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt < out[j].CreatedAt })
	return out
}

func (s *Store) lastMessage(chatID string) *Message {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var last *Message
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ChatID != chatID || m.Deleted || len(m.DeletedFor) > 0 {
			continue
		}
		if last == nil || m.CreatedAt > last.CreatedAt {
			last = m
		}
	}
	return last
}

func (s *Store) unreadCount(chatID, userID string) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ChatID != chatID || m.SenderID == userID || m.Deleted || inSlice(m.DeletedFor, userID) {
			continue
		}
		if !inSlice(m.ReadBy, userID) {
			n++
		}
	}
	return n
}
func (s *Store) userList() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]string, 0, len(s.state.Users))
	for _, u := range s.state.Users {
		out = append(out, u.ID)
	}
	return out
}

// ---------- Mutations ----------

func (s *Store) addUser(name string) User {
	u := User{ID: newID("u"), Name: name}
	s.mu.Lock()
	s.state.Users = append(s.state.Users, u)
	s.mu.Unlock()
	_ = s.save()
	return u
}

func (s *Store) addCommunity(cm Community) {
	s.mu.Lock()
	s.state.Communities = append(s.state.Communities, cm)
	s.mu.Unlock()
	_ = s.save()
}

func (s *Store) createCall(chatID, callerID, callerName, kind string) CallRecord {
	c := CallRecord{
		ID:         newID("call"),
		ChatID:     chatID,
		CallerID:   callerID,
		CallerName: callerName,
		Kind:       kind,
		Status:     "ringing",
		CreatedAt:  time.Now().UnixMilli(),
		UpdatedAt:  time.Now().UnixMilli(),
	}
	s.mu.Lock()
	s.state.CallRecords = append(s.state.CallRecords, c)
	s.mu.Unlock()
	_ = s.save()
	return c
}

func (s *Store) respondCall(callID, status string) (*CallRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.CallRecords {
		c := &s.state.CallRecords[i]
		if c.ID == callID {
			c.Status = status
			c.UpdatedAt = time.Now().UnixMilli()
			_ = s.save()
			return c, true
		}
	}
	return nil, false
}

func (s *Store) addCallLog(c CallLog) CallLog {
	s.mu.Lock()
	s.state.Calls = append(s.state.Calls, c)
	s.mu.Unlock()
	_ = s.save()
	return c
}
func (s *Store) addChat(typ, name string, memberIDs, adminIDs []string) Chat {
	c := Chat{
		ID:        newID("c"),
		Type:      typ,
		Name:      name,
		MemberIDs: memberIDs,
		AdminIDs:  adminIDs,
		CreatedAt: time.Now().UnixMilli(),
	}
	s.mu.Lock()
	s.state.Chats = append(s.state.Chats, c)
	s.mu.Unlock()
	_ = s.save()
	return c
}

func (s *Store) addScheduledCall(sc ScheduledCall) ScheduledCall {
	sc.ID = newID("sc")
	sc.CreatedAt = time.Now().UnixMilli()
	s.mu.Lock()
	s.state.ScheduledCalls = append(s.state.ScheduledCalls, sc)
	s.mu.Unlock()
	_ = s.save()
	return sc
}

func (s *Store) scheduledCallsFor(userID string) []ScheduledCall {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []ScheduledCall{}
	for _, sc := range s.state.ScheduledCalls {
		if sc.UserID == userID || inSlice(sc.MemberIDs, userID) {
			out = append(out, sc)
		}
	}
	return out
}

func (s *Store) toggleScheduledReminder(id string) (*ScheduledCall, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.ScheduledCalls {
		sc := &s.state.ScheduledCalls[i]
		if sc.ID == id {
			sc.Reminder = !sc.Reminder
			_ = s.save()
			return sc, true
		}
	}
	return nil, false
}

func (s *Store) deleteScheduledCall(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.ScheduledCalls {
		if s.state.ScheduledCalls[i].ID == id {
			s.state.ScheduledCalls = append(s.state.ScheduledCalls[:i], s.state.ScheduledCalls[i+1:]...)
			_ = s.save()
			return true
		}
	}
	return false
}

func (s *Store) addMessage(chatID, senderID, typ, text string, media map[string]any, replyTo string) Message {
	m := Message{
		ID:        newID("m"),
		ChatID:    chatID,
		SenderID:  senderID,
		Type:      typ,
		Text:      text,
		Media:     media,
		CreatedAt: time.Now().UnixMilli(),
		Reactions: map[string][]string{},
		ReplyTo:   replyTo,
	}
	s.mu.Lock()
	s.state.Messages = append(s.state.Messages, m)
	s.mu.Unlock()
	_ = s.save()
	return m
}

// addPending queues a message for offline delivery to a specific user.
func (s *Store) addPending(userID string, m Message) {
	s.mu.Lock()
	s.state.Pending = append(s.state.Pending, Pending{UserID: userID, Message: m})
	s.mu.Unlock()
	_ = s.save()
}

// drainPending returns and removes all pending messages for the user.
func (s *Store) drainPending(userID string) []Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Message{}
	rest := s.state.Pending[:0]
	for _, p := range s.state.Pending {
		if p.UserID == userID {
			out = append(out, p.Message)
		} else {
			rest = append(rest, p)
		}
	}
	s.state.Pending = rest
	_ = s.save()
	return out
}

func (s *Store) toggleReaction(msgID, userID, emoji string) (map[string][]string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ID != msgID {
			continue
		}
		if m.Reactions == nil {
			m.Reactions = map[string][]string{}
		}
		users := m.Reactions[emoji]
		if inSlice(users, userID) {
			m.Reactions[emoji] = removeFrom(users, userID)
			if len(m.Reactions[emoji]) == 0 {
				delete(m.Reactions, emoji)
			}
		} else {
			m.Reactions[emoji] = append(users, userID)
		}
		_ = s.save()
		return m.Reactions, true
	}
	return nil, false
}

func (s *Store) editMessage(msgID, userID, text string) (*Message, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ID != msgID {
			continue
		}
		if m.SenderID != userID {
			return nil, false
		}
		m.Text = text
		m.Edited = true
		_ = s.save()
		return m, true
	}
	return nil, false
}

func (s *Store) deleteMessage(msgID, userID, mode string) (*Message, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ID != msgID {
			continue
		}
		if mode == "all" {
			m.Deleted = true
		} else {
			if !inSlice(m.DeletedFor, userID) {
				m.DeletedFor = append(m.DeletedFor, userID)
			}
		}
		_ = s.save()
		return m, true
	}
	return nil, false
}

func (s *Store) votePoll(msgID, userID string, optionIndex int) (*Message, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ID != msgID {
			continue
		}
		if m.Media == nil {
			return nil, false
		}
		opts, ok := m.Media["options"].([]any)
		if !ok || optionIndex < 0 || optionIndex >= len(opts) {
			return nil, false
		}
		voters, _ := m.Media["voters"].([]any)
		if !inSliceAny(voters, userID) {
			voters = append(voters, userID)
			m.Media["voters"] = voters
			_ = s.save()
		}
		return m, true
	}
	return nil, false
}

func inSliceAny(s []any, v string) bool {
	for _, x := range s {
		if str, ok := x.(string); ok && str == v {
			return true
		}
	}
	return false
}

// markRead marks incoming messages as read for the user; returns true if changed.
func (s *Store) markRead(chatID, userID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := false
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ChatID != chatID || m.SenderID == userID {
			continue
		}
		if !inSlice(m.DeliveredTo, userID) {
			m.DeliveredTo = append(m.DeliveredTo, userID)
			changed = true
		}
		if !inSlice(m.ReadBy, userID) {
			m.ReadBy = append(m.ReadBy, userID)
			changed = true
		}
	}
	if changed {
		_ = s.save()
	}
	return changed
}

// ---------- Seed ----------

func seedState() State {
	now := time.Now()
	min := func(n int64) int64 { return now.Add(time.Duration(-n) * time.Minute).UnixMilli() }

	users := []User{
		{ID: "u-julien", Name: "Julien Dumont"},
		{ID: "u-lucas", Name: "Lucas Martin"},
		{ID: "u-emma", Name: "Emma Bernard"},
		{ID: "u-thomas", Name: "Thomas Petit"},
		{ID: "u-sarah", Name: "Sarah Kacem"},
	}

	chats := []Chat{
		{ID: "c-lucas", Type: "dm", Name: "Lucas Martin", MemberIDs: []string{"u-julien", "u-lucas"}, CreatedAt: min(600)},
		{ID: "c-emma", Type: "dm", Name: "Emma Bernard", MemberIDs: []string{"u-julien", "u-emma"}, CreatedAt: min(900)},
		{ID: "c-nova", Type: "group", Name: "Projet Nova", MemberIDs: []string{"u-julien", "u-lucas", "u-emma", "u-thomas", "u-sarah"}, AdminIDs: []string{"u-julien", "u-lucas"}, CreatedAt: min(5000)},
	}

	msgs := []Message{
		// --- Lucas (DM) ---
		{ID: "m-101", ChatID: "c-lucas", SenderID: "u-lucas", Type: "text", Text: "Salut ! Tu viens ce soir ? On se retrouve à 20h devant le cinéma", CreatedAt: min(14), Reactions: map[string][]string{"❤️": {"u-julien", "u-emma"}}, ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},
		{ID: "m-102", ChatID: "c-lucas", SenderID: "u-julien", Type: "text", Text: "Oui ! Je réserve les places", CreatedAt: min(12), ReplyTo: "m-101", ReadBy: []string{"u-lucas"}, DeliveredTo: []string{"u-lucas"}},
		{ID: "m-103", ChatID: "c-lucas", SenderID: "u-lucas", Type: "voice", Media: map[string]any{"duration": 34}, CreatedAt: min(11), ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},
		{ID: "m-104", ChatID: "c-lucas", SenderID: "u-julien", Type: "poll", Text: "Où allons-nous après ?", Media: map[string]any{"options": []any{"Cinéma", "Restaurant", "Bowling"}, "votes": []any{5, 12, 3}, "voters": []any{}}, CreatedAt: min(10), ReadBy: []string{"u-lucas"}, DeliveredTo: []string{"u-lucas"}},
		{ID: "m-105", ChatID: "c-lucas", SenderID: "u-julien", Type: "document", Text: "projet-nova.pdf", Media: map[string]any{"ext": "pdf", "size": "8,4 Mo", "pages": 23}, CreatedAt: min(9), ReadBy: []string{"u-lucas"}, DeliveredTo: []string{"u-lucas"}},
		{ID: "m-106", ChatID: "c-lucas", SenderID: "u-lucas", Type: "image", Media: map[string]any{"name": "IMG_2047.jpg", "once": true}, CreatedAt: min(8), ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},
		{ID: "m-107", ChatID: "c-lucas", SenderID: "u-julien", Type: "text", Text: "On se retrouve à 20h15 alors", CreatedAt: min(7), Edited: true, ReadBy: []string{"u-lucas"}, DeliveredTo: []string{"u-lucas"}, Reactions: map[string][]string{"😂": {"u-lucas"}}},
		{ID: "m-108", ChatID: "c-lucas", SenderID: "u-lucas", Type: "system", Text: "Ce message a été supprimé.", CreatedAt: min(6), Deleted: true},

		// --- Emma (DM) ---
		{ID: "m-201", ChatID: "c-emma", SenderID: "u-emma", Type: "voice", Media: map[string]any{"duration": 47}, CreatedAt: min(200), ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},
		{ID: "m-202", ChatID: "c-emma", SenderID: "u-julien", Type: "text", Text: "Ça marche", CreatedAt: min(195), ReadBy: []string{"u-emma"}, DeliveredTo: []string{"u-emma"}},
		{ID: "m-203", ChatID: "c-emma", SenderID: "u-emma", Type: "image", Media: map[string]any{"name": "IMG_0451.jpg"}, CreatedAt: min(190), ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},
		{ID: "m-204", ChatID: "c-emma", SenderID: "u-emma", Type: "text", Text: "Merci pour les photos !", CreatedAt: min(5), ReadBy: []string{"u-julien"}, DeliveredTo: []string{"u-julien"}},

		// --- Projet Nova (groupe) ---
		{ID: "m-301", ChatID: "c-nova", SenderID: "u-julien", Type: "system", Text: "Vous avez créé le groupe « Projet Nova »", CreatedAt: min(4000), ReadBy: []string{"u-lucas", "u-emma", "u-thomas", "u-sarah"}, DeliveredTo: []string{"u-lucas", "u-emma", "u-thomas", "u-sarah"}},
		{ID: "m-302", ChatID: "c-nova", SenderID: "u-thomas", Type: "text", Text: "Build 2.4 déployé ✅", CreatedAt: min(300), ReadBy: []string{"u-julien", "u-lucas", "u-emma", "u-sarah"}, DeliveredTo: []string{"u-julien", "u-lucas", "u-emma", "u-sarah"}},
		{ID: "m-303", ChatID: "c-nova", SenderID: "u-lucas", Type: "image", Media: map[string]any{"name": "sprint-board.jpg"}, CreatedAt: min(280), ReadBy: []string{"u-julien", "u-emma", "u-thomas", "u-sarah"}, DeliveredTo: []string{"u-julien", "u-emma", "u-thomas", "u-sarah"}},
		{ID: "m-304", ChatID: "c-nova", SenderID: "u-julien", Type: "event", Text: "Réunion projet", Media: map[string]any{"date": "12 septembre", "time": "18:30", "location": "Salle 204", "link": "https://kite.chat/call/nova", "participants": 8, "maybe": 2}, CreatedAt: min(260), ReadBy: []string{"u-lucas", "u-emma", "u-thomas", "u-sarah"}, DeliveredTo: []string{"u-lucas", "u-emma", "u-thomas", "u-sarah"}},
		{ID: "m-305", ChatID: "c-nova", SenderID: "u-sarah", Type: "text", Text: "Revue de sprint jeudi 10h, pensez à préparer vos points", CreatedAt: min(40), ReadBy: []string{"u-julien", "u-lucas", "u-emma", "u-thomas"}, DeliveredTo: []string{"u-julien", "u-lucas", "u-emma", "u-thomas"}},
		{ID: "m-306", ChatID: "c-nova", SenderID: "u-emma", Type: "poll", Text: "Pour la rétro, quel créneau ?", Media: map[string]any{"options": []any{"Jeudi 9h", "Jeudi 14h", "Vendredi 9h"}, "votes": []any{3, 6, 2}, "voters": []any{}}, CreatedAt: min(20), ReadBy: []string{"u-julien", "u-lucas", "u-thomas", "u-sarah"}, DeliveredTo: []string{"u-julien", "u-lucas", "u-thomas", "u-sarah"}},
	}

	// Un message en attente pour Julien (offline -> livré au premier connect SSE).
	msgs = append(msgs, Message{ID: "m-109", ChatID: "c-lucas", SenderID: "u-lucas", Type: "text", Text: "Ça marche, à tout à l'heure ! 👋", CreatedAt: min(1)})
	pending := []Pending{
		{UserID: "u-julien", Message: msgs[len(msgs)-1]},
	}

	// --- Communautés (sous-ensembles de groupes) ---
	communities := []Community{
		{ID: "cm-robot", Name: "Club Robotique", Description: "Bricolage, impression 3D et projets électroniques.", GroupIDs: []string{}, CreatedAt: min(8000)},
		{ID: "cm-ecole", Name: "École", Description: "Groupe de la promo et de l'atelier design.", GroupIDs: []string{}, CreatedAt: min(7000)},
		{ID: "cm-famille", Name: "Famille", Description: "Le grand groupe familial.", GroupIDs: []string{}, CreatedAt: min(6000)},
	}
	// Affectation des groupes existants aux communautés. c-nova est membre de
	// la communauté « Club Robotique ».
	communities[0].GroupIDs = []string{"c-nova", "g-print3d", "g-electro"}
	// Les groupes rattachés doivent exister en tant que chats pour que l'UI
	// puisse ouvrir une conversation. On ajoute deux groupes filles à la communauté.
	groups := []Chat{
		{ID: "g-print3d", Type: "group", Name: "Impression 3D", MemberIDs: []string{"u-julien", "u-thomas", "u-sarah"}, AdminIDs: []string{"u-julien"}, CreatedAt: min(700)},
		{ID: "g-electro", Type: "group", Name: "Électronique", MemberIDs: []string{"u-julien", "u-lucas", "u-thomas"}, AdminIDs: []string{"u-lucas"}, CreatedAt: min(680)},
		{ID: "g-design", Type: "group", Name: "Atelier design", MemberIDs: []string{"u-julien", "u-emma", "u-sarah"}, AdminIDs: []string{"u-emma"}, CreatedAt: min(900)},
	}
	chats = append(chats, groups...)

	// --- Appels (onglet Appels) ---
	calls := []CallLog{
		{ID: "cl-1", Type: "audio", UserID: "u-lucas", Name: "Lucas Martin", Direction: "incoming", CreatedAt: min(30), CompletedAt: min(28)},
		{ID: "cl-2", Type: "video", UserID: "u-emma", Name: "Emma Bernard", Direction: "outgoing", IsVideo: true, CreatedAt: min(150), CompletedAt: min(145)},
		{ID: "cl-3", Type: "audio", UserID: "u-lucas", Name: "Lucas Martin", Direction: "missed", CreatedAt: min(200)},
		{ID: "cl-4", Type: "audio", UserID: "u-thomas", Name: "Thomas Petit", Direction: "incoming", CreatedAt: min(400), CompletedAt: min(398)},
		{ID: "cl-5", Type: "video", UserID: "c-nova", Name: "Projet Nova", Group: true, IsVideo: true, Direction: "outgoing", CreatedAt: min(600), CompletedAt: min(560)},
		{ID: "cl-6", Type: "audio", UserID: "u-sarah", Name: "Sarah Kacem", Direction: "missed", CreatedAt: min(800)},
	}

	// --- Appels planifiés (démo) ---
	hoursLater := func(n int) int64 { return now.Add(time.Duration(n) * time.Hour).UnixMilli() }
	scheduled := []ScheduledCall{
		{ID: "sc-demo1", Title: "Point d'équipe", UserID: "u-julien", MemberIDs: []string{"u-lucas", "u-emma", "u-thomas", "u-sarah"}, ChatID: "c-nova", ScheduledAt: hoursLater(24), Kind: "video", Reminder: true},
		{ID: "sc-demo2", Title: "Catch-up Lucas", UserID: "u-julien", MemberIDs: []string{"u-lucas"}, ChatID: "c-lucas", ScheduledAt: hoursLater(3), Kind: "audio", Reminder: false},
	}

	state := State{
		Users:          users,
		Chats:          chats,
		Messages:       msgs,
		Pending:        pending,
		Communities:    communities,
		Calls:          calls,
		SeedVersion:    seedVersion,
		ScheduledCalls: scheduled,
	}
	return state
}
