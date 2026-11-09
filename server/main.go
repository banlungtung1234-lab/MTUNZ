package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	maxRoomPeers   = 3
	maxActiveRooms = 64
	roomTTL        = 15 * time.Minute
	maxBody        = 32 << 10
	maxQueue       = 32
	maxRateEntries = 10000
	peerIdleTTL    = 90 * time.Second
)

type Room struct {
	Code      string
	JoinPin   string
	ExpiresAt time.Time
	Peers     map[string]*Peer
}

type Peer struct {
	ID        string
	Name      string
	Events    chan Message
	PollSlots chan struct{}
	Token     string
	LastSeen  time.Time
	Done      chan struct{}
}

type rateLimitEntry struct {
	count   int
	resetAt time.Time
}

type Server struct {
	mu         sync.Mutex
	rooms      map[string]*Room
	joinRate   map[string]rateLimitEntry
	createRate map[string]rateLimitEntry
}

type Message struct {
	Type   string          `json:"type"`
	From   string          `json:"from,omitempty"`
	To     string          `json:"to,omitempty"`
	PeerID string          `json:"peerId,omitempty"`
	Peer   *PeerSummary    `json:"peer,omitempty"`
	Peers  []PeerSummary   `json:"peers,omitempty"`
	Data   json.RawMessage `json:"data,omitempty"`
}

type PeerSummary struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type createRoomResponse struct {
	Code      string `json:"code"`
	ExpiresIn int    `json:"expiresInSeconds"`
	JoinPin   string `json:"joinPin"`
}

type joinRequest struct {
	PeerID  string `json:"peerId"`
	Name    string `json:"name"`
	JoinPin string `json:"joinPin"`
}

type joinResponse struct {
	Peers     []PeerSummary `json:"peers"`
	PeerToken string        `json:"peerToken"`
}

func main() {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "mtunz-signaling", "version": "0.1.2-dev"})
	})
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("GET /api/rooms/{code}/events", s.pollEvents)
	mux.HandleFunc("POST /api/rooms/{code}/signal", s.sendSignal)
	mux.HandleFunc("POST /api/rooms/{code}/leave", s.leaveRoom)

	addr := env("MTUNZ_ADDR", ":8787")
	log.Printf("MTUNZ signaling server listening on %s", addr)
	log.Printf("For public Internet use, put this server behind HTTPS/WSS TLS termination.")
	server := &http.Server{
		Addr: addr, Handler: securityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second, // pollEvents waits at most 20 seconds
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			s.mu.Lock()
			s.cleanupLocked()
			s.mu.Unlock()
		}
	}()
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func newServer() *Server {
	return &Server{
		rooms:      make(map[string]*Room),
		joinRate:   make(map[string]rateLimitEntry),
		createRate: make(map[string]rateLimitEntry),
	}
}

func (s *Server) allowAttempt(ip string, bucket map[string]rateLimitEntry, limit int) bool {
	now := time.Now()
	entry, exists := bucket[ip]
	if !exists || !now.Before(entry.resetAt) {
		if !exists && len(bucket) >= maxRateEntries {
			for key, candidate := range bucket {
				if !now.Before(candidate.resetAt) {
					delete(bucket, key)
				}
			}
			if len(bucket) >= maxRateEntries {
				return false // fail closed rather than allowing unbounded memory growth
			}
		}
		entry = rateLimitEntry{resetAt: now.Add(5 * time.Minute)}
	}
	entry.count++
	bucket[ip] = entry
	return entry.count <= limit
}

func (s *Server) allowJoinAttempt(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.allowAttempt(ip, s.joinRate, 12)
}

func (s *Server) allowCreateAttempt(ip string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.allowAttempt(ip, s.createRate, 6)
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) createRoom(w http.ResponseWriter, r *http.Request) {
	if !s.allowCreateAttempt(clientIP(r)) {
		http.Error(w, "too many room creation attempts; try again later", http.StatusTooManyRequests)
		return
	}
	code, err := randomCode(8)
	if err != nil {
		http.Error(w, "could not create room", http.StatusInternalServerError)
		return
	}
	s.mu.Lock()
	s.cleanupLocked()
	if len(s.rooms) >= maxActiveRooms {
		s.mu.Unlock()
		http.Error(w, "server has reached its active room limit; try again later", http.StatusServiceUnavailable)
		return
	}
	for s.rooms[code] != nil {
		code, err = randomCode(8)
		if err != nil {
			s.mu.Unlock()
			http.Error(w, "could not create room", 500)
			return
		}
	}
	pin, err := randomDigits(6)
	if err != nil {
		s.mu.Unlock()
		http.Error(w, "could not create room", http.StatusInternalServerError)
		return
	}
	s.rooms[code] = &Room{Code: code, JoinPin: pin, ExpiresAt: time.Now().Add(roomTTL), Peers: make(map[string]*Peer)}
	s.mu.Unlock()
	writeJSON(w, http.StatusCreated, createRoomResponse{Code: code, JoinPin: pin, ExpiresIn: int(roomTTL.Seconds())})
}

func (s *Server) joinRoom(w http.ResponseWriter, r *http.Request) {
	if !s.allowJoinAttempt(clientIP(r)) {
		http.Error(w, "too many invitation attempts; try again later", http.StatusTooManyRequests)
		return
	}
	var req joinRequest
	if err := decodeJSON(w, r, &req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	req.PeerID = strings.TrimSpace(req.PeerID)
	req.Name = strings.TrimSpace(req.Name)
	if len(req.PeerID) < 8 || len(req.PeerID) > 80 {
		http.Error(w, "invalid peerId", http.StatusBadRequest)
		return
	}
	if len(req.JoinPin) != 6 || strings.Trim(req.JoinPin, "0123456789") != "" {
		http.Error(w, "invalid invitation PIN format", http.StatusBadRequest)
		return
	}
	if req.Name == "" {
		req.Name = "MTUNZ device"
	}
	nameRunes := []rune(req.Name)
	if len(nameRunes) > 48 {
		req.Name = string(nameRunes[:48])
	}

	s.mu.Lock()
	s.cleanupLocked()
	room := s.rooms[strings.ToUpper(strings.TrimSpace(r.PathValue("code")))]
	if room == nil || !time.Now().Before(room.ExpiresAt) || subtle.ConstantTimeCompare([]byte(req.JoinPin), []byte(room.JoinPin)) != 1 {
		s.mu.Unlock()
		http.Error(w, "room not found or invitation PIN invalid", http.StatusNotFound)
		return
	}
	if room.Peers[req.PeerID] != nil {
		s.mu.Unlock()
		http.Error(w, "peer already joined", http.StatusConflict)
		return
	}
	if len(room.Peers) >= maxRoomPeers {
		s.mu.Unlock()
		http.Error(w, "room is full (maximum 3 devices)", http.StatusConflict)
		return
	}
	existing := make([]PeerSummary, 0, len(room.Peers))
	for _, p := range room.Peers {
		if len(p.Events) >= cap(p.Events) {
			s.mu.Unlock()
			http.Error(w, "room signaling queue is busy; retry shortly", http.StatusServiceUnavailable)
			return
		}
		existing = append(existing, PeerSummary{ID: p.ID, Name: p.Name})
	}
	peerToken, err := randomHex(32)
	if err != nil {
		s.mu.Unlock()
		http.Error(w, "could not join room", http.StatusInternalServerError)
		return
	}
	peer := &Peer{
		ID: req.PeerID, Name: req.Name,
		Events: make(chan Message, maxQueue), PollSlots: make(chan struct{}, 1), Token: peerToken,
		LastSeen: time.Now(), Done: make(chan struct{}),
	}
	room.Peers[req.PeerID] = peer
	for _, p := range room.Peers {
		if p.ID != peer.ID {
			// Capacity was checked while holding the room lock; polling can only
			// reduce queue depth, so this enqueue cannot overflow.
			if !enqueue(p, Message{Type: "peer-joined", Peer: &PeerSummary{ID: peer.ID, Name: peer.Name}}) {
				delete(room.Peers, peer.ID)
				s.mu.Unlock()
				http.Error(w, "room signaling queue is busy; retry shortly", http.StatusServiceUnavailable)
				return
			}
		}
	}
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, joinResponse{Peers: existing, PeerToken: peerToken})
}

func (s *Server) pollEvents(w http.ResponseWriter, r *http.Request) {
	peerID := strings.TrimSpace(r.URL.Query().Get("peerId"))
	if peerID == "" {
		http.Error(w, "peerId required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	room := s.rooms[strings.ToUpper(strings.TrimSpace(r.PathValue("code")))]
	var peer *Peer
	if room != nil && time.Now().Before(room.ExpiresAt) {
		peer = room.Peers[peerID]
	}
	token := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if peer != nil && subtle.ConstantTimeCompare([]byte(token), []byte(peer.Token)) != 1 {
		peer = nil
	} else if peer != nil {
		// A successful long-poll is also a lightweight presence heartbeat.
		peer.LastSeen = time.Now()
	}
	s.mu.Unlock()
	if peer == nil {
		http.Error(w, "peer not joined or room expired", http.StatusNotFound)
		return
	}
	select {
	case <-peer.Done:
		http.Error(w, "peer session expired", http.StatusNotFound)
		return
	default:
	}
	select {
	case peer.PollSlots <- struct{}{}:
		defer func() { <-peer.PollSlots }()
	default:
		http.Error(w, "a long-poll request is already active for this device", http.StatusConflict)
		return
	}

	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	messages := make([]Message, 0, 8)
	select {
	case msg := <-peer.Events:
		messages = append(messages, msg)
	case <-peer.Done:
		http.Error(w, "peer session expired", http.StatusNotFound)
		return
	case <-timer.C:
		writeJSON(w, http.StatusOK, messages)
		return
	case <-r.Context().Done():
		return
	}
	for len(messages) < 32 {
		select {
		case msg := <-peer.Events:
			messages = append(messages, msg)
		case <-peer.Done:
			http.Error(w, "peer session expired", http.StatusNotFound)
			return
		default:
			writeJSON(w, http.StatusOK, messages)
			return
		}
	}
	writeJSON(w, http.StatusOK, messages)
}

func (s *Server) sendSignal(w http.ResponseWriter, r *http.Request) {
	var msg Message
	if err := decodeJSON(w, r, &msg); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if len(msg.From) < 8 || len(msg.From) > 80 || len(msg.To) < 8 || len(msg.To) > 80 || msg.To == msg.From || msg.Type == "" {
		http.Error(w, "valid from, to and type are required", http.StatusBadRequest)
		return
	}
	if msg.Type != "offer" && msg.Type != "answer" && msg.Type != "candidate" && msg.Type != "control-request" && msg.Type != "control-grant" && msg.Type != "control-revoke" && msg.Type != "renegotiate-request" {
		http.Error(w, "unsupported message type", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	room := s.rooms[strings.ToUpper(strings.TrimSpace(r.PathValue("code")))]
	token := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if room == nil || !time.Now().Before(room.ExpiresAt) || room.Peers[msg.From] == nil || subtle.ConstantTimeCompare([]byte(room.Peers[msg.From].Token), []byte(token)) != 1 {
		s.mu.Unlock()
		http.Error(w, "sender not joined or room expired", http.StatusNotFound)
		return
	}
	target := room.Peers[msg.To]
	if target == nil {
		s.mu.Unlock()
		http.Error(w, "target peer not found", http.StatusNotFound)
		return
	}
	room.Peers[msg.From].LastSeen = time.Now()
	if !enqueue(target, msg) {
		s.mu.Unlock()
		http.Error(w, "target signaling queue is full; retry shortly", http.StatusServiceUnavailable)
		return
	}
	s.mu.Unlock()
	w.WriteHeader(http.StatusAccepted)
}

func (s *Server) leaveRoom(w http.ResponseWriter, r *http.Request) {
	peerID := strings.TrimSpace(r.URL.Query().Get("peerId"))
	code := strings.ToUpper(strings.TrimSpace(r.PathValue("code")))
	s.mu.Lock()
	s.cleanupLocked()
	room := s.rooms[code]
	token := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	var peer *Peer
	if room != nil {
		peer = room.Peers[peerID]
	}
	if peer == nil || subtle.ConstantTimeCompare([]byte(peer.Token), []byte(token)) != 1 {
		s.mu.Unlock()
		http.Error(w, "room or peer not found", http.StatusNotFound)
		return
	}
	s.removePeerLocked(room, peerID)
	if len(room.Peers) == 0 {
		delete(s.rooms, code)
	}
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// removePeerLocked closes the peer's presence channel and notifies the remaining
// participants. The room mutex must be held by the caller.
func (s *Server) removePeerLocked(room *Room, peerID string) {
	peer := room.Peers[peerID]
	if peer == nil {
		return
	}
	delete(room.Peers, peerID)
	if peer.Done != nil {
		close(peer.Done)
	}
	for _, target := range room.Peers {
		if !enqueue(target, Message{Type: "peer-left", PeerID: peerID}) {
			// A leave notification is more useful than a stale queued candidate.
			select {
			case <-target.Events:
			default:
			}
			_ = enqueue(target, Message{Type: "peer-left", PeerID: peerID})
		}
	}
}

func (s *Server) cleanupLocked() {
	now := time.Now()
	for code, room := range s.rooms {
		if !now.Before(room.ExpiresAt) {
			for _, peer := range room.Peers {
				if peer.Done != nil {
					close(peer.Done)
				}
			}
			delete(s.rooms, code)
			continue
		}
		// A new invitation room is intentionally empty until its first peer joins.
		// Only remove an empty room here if cleanup evicted its last existing peer.
		hadPeers := len(room.Peers) > 0
		for peerID, peer := range room.Peers {
			// A client that crashes or loses power stops long-polling. Expire its
			// membership so the room does not remain occupied for the full TTL.
			if !peer.LastSeen.IsZero() && now.Sub(peer.LastSeen) > peerIdleTTL {
				s.removePeerLocked(room, peerID)
			}
		}
		if hadPeers && len(room.Peers) == 0 {
			delete(s.rooms, code)
		}
	}
	for ip, entry := range s.joinRate {
		if !now.Before(entry.resetAt) {
			delete(s.joinRate, ip)
		}
	}
	for ip, entry := range s.createRate {
		if !now.Before(entry.resetAt) {
			delete(s.createRate, ip)
		}
	}
}
func enqueue(p *Peer, msg Message) bool {
	select {
	case p.Events <- msg:
		return true
	default:
		return false
	}
}
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return errors.New("multiple JSON values")
	}
	return nil
}
func randomCode(n int) (string, error) {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	out := make([]byte, n)
	limit := big.NewInt(int64(len(alphabet)))
	for i := range out {
		index, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		out[i] = alphabet[index.Int64()]
	}
	return string(out), nil
}
func randomDigits(n int) (string, error) {
	out := make([]byte, n)
	limit := big.NewInt(10)
	for i := range out {
		digit, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		out[i] = byte('0' + digit.Int64())
	}
	return string(out), nil
}
func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}
func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
