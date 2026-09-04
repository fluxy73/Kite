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
	ID    string `json:"id"`
	Name  string `json:"name"`
	Phone string `json:"phone,omitempty"` // E.164-ish, für Kontakt-Matching
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

// ScheduledMessage est un message qui sera délivré automatiquement dans
// une conversation à son échéance (comportement type WhatsApp).
type ScheduledMessage struct {
	ID          string `json:"id"`
	ChatID      string `json:"chatId"`
	SenderID    string `json:"senderId"`
	Text        string `json:"text,omitempty"`
	ReplyTo     string `json:"replyTo,omitempty"`
	ScheduledAt int64  `json:"scheduledAt"` // timestamp de livraison
	CreatedAt   int64  `json:"createdAt"`
}

type Chat struct {
	ID         string   `json:"id"`
	Type       string   `json:"type"` // dm | group | community
	Name       string   `json:"name"`
	MemberIDs  []string `json:"memberIds"`
	AdminIDs   []string `json:"adminIds"`
	CreatedAt  int64    `json:"createdAt"`
	Archived   []string `json:"archived,omitempty"`   // userIds ayant archivé cette conversation
	Pinned     []string `json:"pinned,omitempty"`     // userIds ayant épinglé cette conversation
	DeletedFor []string `json:"deletedFor,omitempty"` // userIds ayant supprimé la discussion pour eux
	// Mutes : expiration du sourdine par utilisateur (0 = pas muet).
	Mutes map[string]int64 `json:"mutes,omitempty"`
	// Notifs : préférences de notification par utilisateur (priorité,
	// son, aperçu). Map vide = défauts de l'app.
	Notifs map[string]NotifPrefs `json:"notifs,omitempty"`
	// Disappearing : durée des messages éphémères en ms (0 = désactivé).
	// Les messages envoyés pendant que le minuteur est actif portent un
	// ExpiresAt = createdAt + Disappearing.
	Disappearing int64 `json:"disappearing,omitempty"`
}

// NotifPrefs : préférences de notification par conversation et par
// utilisateur. Priorité : low | default | high. Son et aperçu : on/off.
type NotifPrefs struct {
	Priority string `json:"priority,omitempty"` // low | default | high
	Sound    *bool  `json:"sound,omitempty"`
	Preview  *bool  `json:"preview,omitempty"`
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
	StarredBy   []string            `json:"starredBy,omitempty"` // userIds ayant mis en favori
	ExpiresAt   int64               `json:"expiresAt,omitempty"` // éphémère : disparait après (epoch ms)
}

type Pending struct {
	UserID  string  `json:"userId"`
	Message Message `json:"message"`
}

type State struct {
	Users          []User             `json:"users"`
	Chats          []Chat             `json:"chats"`
	Messages       []Message          `json:"messages"`
	Pending        []Pending          `json:"pending"`
	Calls          []CallLog          `json:"calls"`
	CallRecords    []CallRecord       `json:"callRecords"`
	ScheduledCalls []ScheduledCall    `json:"scheduledCalls"`
	ScheduledMsgs  []ScheduledMessage `json:"scheduledMessages"`
	// NotifDefaults : défauts de notification globaux par utilisateur
	// (toutes ses conversations sans préférence propre).
	NotifDefaults map[string]NotifPrefs `json:"notifDefaults,omitempty"`
	SeedVersion   int                   `json:"seedVersion"`
}

// seedVersion is bumped whenever the shape of seedState() changes, so an
// existing data file is regenerated on the next start.
const seedVersion = 6

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

func removeFromSlice(s []string, v string) []string {
	out := make([]string, 0, len(s))
	for _, x := range s {
		if x != v {
			out = append(out, x)
		}
	}
	return out
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

// setDisappearing règle le minuteur des messages éphémères de la
// conversation (ms ; 0 = désactivé). Réglage global à la conversation,
// comme WhatsApp.
func (s *Store) setDisappearing(chatID string, ms int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		if s.state.Chats[i].ID == chatID {
			s.state.Chats[i].Disappearing = ms
			_ = s.save()
			return true
		}
	}
	return false
}

// expireSweep retire définitivement tous les messages éphémères échus et
// retourne (chatID, ids) par conversation pour diffusion de l'événement.
func (s *Store) expireSweep(now int64) map[string][]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	sweep := map[string][]string{}
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ExpiresAt > 0 && m.ExpiresAt <= now && !m.Deleted {
			m.Deleted = true
			sweep[m.ChatID] = append(sweep[m.ChatID], m.ID)
		}
	}
	if len(sweep) > 0 {
		_ = s.save()
	}
	return sweep
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
		if m.ExpiresAt > 0 && m.ExpiresAt <= time.Now().UnixMilli() {
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
		// Masque la conversation pour ceux qui l'ont supprimée (pour eux).
		if !inSlice(c.MemberIDs, userID) || inSlice(c.DeletedFor, userID) {
			continue
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		pi, pj := inSlice(out[i].Pinned, userID), inSlice(out[j].Pinned, userID)
		if pi != pj {
			return pi // épinglées d'abord
		}
		return out[i].CreatedAt < out[j].CreatedAt
	})
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
	for i := range s.state.Chats {
		if s.state.Chats[i].ID == chatID {
			// Conversation muette : le compteur reste à 0 tant que la
			// sourdine est active (les messages restent eux non lus).
			if mutedUntil(s.state.Chats[i].Mutes, userID) > 0 {
				return 0
			}
			break
		}
	}
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

func (s *Store) callByID(id string) (CallRecord, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.state.CallRecords {
		if c.ID == id {
			return c, true
		}
	}
	return CallRecord{}, false
}

// toggleStar marque/démarque un message en favori pour un utilisateur.
func (s *Store) toggleStar(messageID, userID string) ([]string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Messages {
		m := &s.state.Messages[i]
		if m.ID != messageID {
			continue
		}
		found := false
		for _, u := range m.StarredBy {
			if u == userID {
				found = true
				break
			}
		}
		if found {
			out := make([]string, 0, len(m.StarredBy))
			for _, u := range m.StarredBy {
				if u != userID {
					out = append(out, u)
				}
			}
			m.StarredBy = out
		} else {
			m.StarredBy = append(m.StarredBy, userID)
		}
		_ = s.save()
		return m.StarredBy, true
	}
	return nil, false
}

// setPinned épingle ou détache une conversation pour un utilisateur.
func (s *Store) setPinned(chatID, userID string, pinned bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		c := &s.state.Chats[i]
		if c.ID != chatID {
			continue
		}
		found := inSlice(c.Pinned, userID)
		if pinned && !found {
			c.Pinned = append(c.Pinned, userID)
		} else if !pinned && found {
			c.Pinned = removeFromSlice(c.Pinned, userID)
		}
		_ = s.save()
		return true
	}
	return false
}

// deleteChatFor supprime la conversation pour cet utilisateur uniquement :
// elle disparaît de sa liste, l'historique et les autres membres sont
// conservés. Un nouveau message la fait renaître (comportement WhatsApp).
func (s *Store) deleteChatFor(chatID, userID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		c := &s.state.Chats[i]
		if c.ID != chatID || !inSlice(c.MemberIDs, userID) {
			continue
		}
		if !inSlice(c.DeletedFor, userID) {
			c.DeletedFor = append(c.DeletedFor, userID)
		}
		// Épinglage, archivage et sourdine personnels : nettoyés avec la
		// suppression.
		c.Pinned = removeFromSlice(c.Pinned, userID)
		c.Archived = removeFromSlice(c.Archived, userID)
		if c.Mutes != nil {
			delete(c.Mutes, userID)
		}
		if c.Notifs != nil {
			delete(c.Notifs, userID)
		}
		_ = s.save()
		return true
	}
	return false
}

// setArchived archive ou désarchive une conversation pour un utilisateur.
func (s *Store) setArchived(chatID, userID string, archived bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		c := &s.state.Chats[i]
		if c.ID != chatID {
			continue
		}
		found := false
		for _, u := range c.Archived {
			if u == userID {
				found = true
				break
			}
		}
		if archived && !found {
			c.Archived = append(c.Archived, userID)
		} else if !archived && found {
			out := make([]string, 0, len(c.Archived))
			for _, u := range c.Archived {
				if u != userID {
					out = append(out, u)
				}
			}
			c.Archived = out
		}
		_ = s.save()
		return true
	}
	return false
}

// SetNotifDefaults enregistre les défauts de notification globaux de userID
// (prefs vide = remise aux défauts de l'app).
func (s *Store) SetNotifDefaults(userID string, prefs NotifPrefs) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.NotifDefaults == nil {
		s.state.NotifDefaults = map[string]NotifPrefs{}
	}
	if prefs.Priority == "" && prefs.Sound == nil && prefs.Preview == nil {
		delete(s.state.NotifDefaults, userID)
	} else {
		s.state.NotifDefaults[userID] = prefs
	}
	_ = s.save()
}

// notifDefaultsFor retourne les défauts de notification globaux de userID
// (valeur zéro s'ils ne sont pas définis).
func (s *Store) notifDefaultsFor(userID string) NotifPrefs {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.NotifDefaults[userID]
}

// mutedForUser indique si la sourdine de userID est active sur chatID.
func (s *Store) mutedForUser(chatID, userID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for i := range s.state.Chats {
		if s.state.Chats[i].ID == chatID {
			return mutedUntil(s.state.Chats[i].Mutes, userID) > 0
		}
	}
	return false
}

// SetNotifs enregistre les préférences de notification de userID sur
// chatID (prefs nil = remise aux défauts).
func (s *Store) SetNotifs(chatID, userID string, prefs NotifPrefs) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		c := &s.state.Chats[i]
		if c.ID != chatID {
			continue
		}
		if prefs.Priority == "" && prefs.Sound == nil && prefs.Preview == nil {
			if c.Notifs != nil {
				delete(c.Notifs, userID)
			}
		} else {
			if c.Notifs == nil {
				c.Notifs = map[string]NotifPrefs{}
			}
			c.Notifs[userID] = prefs
		}
		_ = s.save()
		return true
	}
	return false
}

// mutedUntil retourne l'échéance de sourdine active de userID (> 0), 0 sinon.
func mutedUntil(mutes map[string]int64, userID string) int64 {
	u, ok := mutes[userID]
	if !ok || u <= time.Now().UnixMilli() {
		return 0
	}
	return u
}

// SetMute rend muet (until > now) ou démute (until <= 0) une conversation
// pour un utilisateur.
func (s *Store) SetMute(chatID, userID string, until int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Chats {
		c := &s.state.Chats[i]
		if c.ID != chatID {
			continue
		}
		if until <= 0 {
			if c.Mutes != nil {
				delete(c.Mutes, userID)
			}
		} else {
			if c.Mutes == nil {
				c.Mutes = map[string]int64{}
			}
			c.Mutes[userID] = until
		}
		_ = s.save()
		return true
	}
	return false
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

// addScheduledMessage enregistre un message programmé.
func (s *Store) addScheduledMessage(sm ScheduledMessage) ScheduledMessage {
	sm.ID = newID("sm")
	sm.CreatedAt = time.Now().UnixMilli()
	s.mu.Lock()
	s.state.ScheduledMsgs = append(s.state.ScheduledMsgs, sm)
	s.mu.Unlock()
	_ = s.save()
	return sm
}

// scheduledMessagesFor liste les messages programmés visibles par userID
// (créateur ou membre de la conversation).
func (s *Store) scheduledMessagesFor(userID string) []ScheduledMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()
	// Un seul passage RLock : memberOf reprendrait le verrou (non réentrant).
	member := map[string]bool{}
	for i := range s.state.Chats {
		if inSlice(s.state.Chats[i].MemberIDs, userID) {
			member[s.state.Chats[i].ID] = true
		}
	}
	out := []ScheduledMessage{}
	for _, sm := range s.state.ScheduledMsgs {
		if sm.SenderID == userID || member[sm.ChatID] {
			out = append(out, sm)
		}
	}
	return out
}

// deleteScheduledMessage supprime un message programmé (créateur uniquement).
func (s *Store) deleteScheduledMessage(id, userID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.ScheduledMsgs {
		sm := &s.state.ScheduledMsgs[i]
		if sm.ID == id && sm.SenderID == userID {
			s.state.ScheduledMsgs = append(s.state.ScheduledMsgs[:i], s.state.ScheduledMsgs[i+1:]...)
			_ = s.save()
			return true
		}
	}
	return false
}

// dueScheduledMessages extrait et retire tous les messages programmés
// arrivés à échéance. Retourne aussi les IDs des conversations touchées.
func (s *Store) dueScheduledMessages(now int64) []ScheduledMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	due := []ScheduledMessage{}
	rest := s.state.ScheduledMsgs[:0]
	for _, sm := range s.state.ScheduledMsgs {
		if sm.ScheduledAt <= now {
			due = append(due, sm)
		} else {
			rest = append(rest, sm)
		}
	}
	if len(due) > 0 {
		s.state.ScheduledMsgs = rest
		_ = s.save()
	}
	return due
}

func (s *Store) addMessage(chatID, senderID, typ, text string, media map[string]any, replyTo string) Message {
	s.mu.Lock()
	var exp int64
	for i := range s.state.Chats {
		if s.state.Chats[i].ID == chatID {
			// Un nouveau message fait renaître la conversation pour tous ceux
			// qui l'avaient supprimée (comportement WhatsApp).
			s.state.Chats[i].DeletedFor = nil
			// Éphémère : horodatage d'après le minuteur de la conversation
			// (les messages système restent visibles).
			if typ != "system" && s.state.Chats[i].Disappearing > 0 {
				exp = time.Now().UnixMilli() + s.state.Chats[i].Disappearing
			}
			break
		}
	}
	m := Message{
		ID:        newID("m"),
		ChatID:    chatID,
		SenderID:  senderID,
		Type:      typ,
		Text:      text,
		Media:     media,
		CreatedAt: time.Now().UnixMilli(),
		ExpiresAt: exp,
		Reactions: map[string][]string{},
		ReplyTo:   replyTo,
	}
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
		{ID: "u-julien", Name: "Julien Dumont", Phone: "+33612345678"},
		{ID: "u-lucas", Name: "Lucas Martin", Phone: "+33698765432"},
		{ID: "u-emma", Name: "Emma Bernard", Phone: "+33655544433"},
		{ID: "u-thomas", Name: "Thomas Petit", Phone: "+33622233344"},
		{ID: "u-sarah", Name: "Sarah Kacem", Phone: "+33677788899"},
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

	// --- Zusätzliche Gruppen (ehem. Community-Kinder, jetzt normale Gruppen) ---
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

	scheduledMsgs := []ScheduledMessage{
		{ID: "sm-demo1", ChatID: "c-lucas", SenderID: "u-julien", Text: "Bon anniversaire 🎂", ScheduledAt: now.Add(48 * time.Hour).UnixMilli()},
	}

	state := State{
		Users:          users,
		Chats:          chats,
		Messages:       msgs,
		Pending:        pending,
		Calls:          calls,
		SeedVersion:    seedVersion,
		ScheduledCalls: scheduled,
		ScheduledMsgs:  scheduledMsgs,
	}
	return state
}
