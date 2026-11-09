package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCreateJoinAndSignal(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("POST /api/rooms/{code}/signal", s.sendSignal)

	create := httptest.NewRecorder()
	mux.ServeHTTP(create, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	if create.Code != http.StatusCreated {
		t.Fatalf("create status %d", create.Code)
	}
	var cr createRoomResponse
	if err := json.Unmarshal(create.Body.Bytes(), &cr); err != nil {
		t.Fatal(err)
	}

	join := func(peer string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(joinRequest{PeerID: peer, Name: peer, JoinPin: cr.JoinPin})
		r := httptest.NewRequest(http.MethodPost, "/api/rooms/"+cr.Code+"/join", bytes.NewReader(b))
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, r)
		return w
	}
	if w := join("peer-alpha-123"); w.Code != http.StatusOK {
		t.Fatalf("join alpha: %d %s", w.Code, w.Body.String())
	}
	if w := join("peer-bravo-123"); w.Code != http.StatusOK {
		t.Fatalf("join bravo: %d %s", w.Code, w.Body.String())
	}

	data := json.RawMessage(`{"sdp":"test"}`)
	body, _ := json.Marshal(Message{Type: "offer", From: "peer-alpha-123", To: "peer-bravo-123", Data: data})
	r := httptest.NewRequest(http.MethodPost, "/api/rooms/"+cr.Code+"/signal", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+s.rooms[cr.Code].Peers["peer-alpha-123"].Token)
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != http.StatusAccepted {
		t.Fatalf("signal: %d %s", w.Code, w.Body.String())
	}
	got := <-s.rooms[cr.Code].Peers["peer-bravo-123"].Events
	if got.Type != "offer" || got.From != "peer-alpha-123" {
		t.Fatalf("unexpected signal: %#v", got)
	}
}

func TestRoomLimitAndLeaveCaseInsensitive(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("POST /api/rooms/{code}/leave", s.leaveRoom)

	create := httptest.NewRecorder()
	mux.ServeHTTP(create, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(create.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}

	var firstToken string
	for i, id := range []string{"peer-alpha-123", "peer-bravo-123", "peer-charlie-123"} {
		body, _ := json.Marshal(joinRequest{PeerID: id, Name: id, JoinPin: invite.JoinPin})
		request := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(body))
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("join %s: %d %s", id, response.Code, response.Body.String())
		}
		if i == 0 {
			var joined joinResponse
			if err := json.Unmarshal(response.Body.Bytes(), &joined); err != nil {
				t.Fatal(err)
			}
			firstToken = joined.PeerToken
		}
	}

	fourthBody, _ := json.Marshal(joinRequest{PeerID: "peer-delta-123", Name: "fourth", JoinPin: invite.JoinPin})
	fourthRequest := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(fourthBody))
	fourthResponse := httptest.NewRecorder()
	mux.ServeHTTP(fourthResponse, fourthRequest)
	if fourthResponse.Code != http.StatusConflict {
		t.Fatalf("expected room-full conflict, got %d", fourthResponse.Code)
	}

	leaveRequest := httptest.NewRequest(http.MethodPost, "/api/rooms/"+strings.ToLower(invite.Code)+"/leave?peerId=peer-alpha-123", bytes.NewReader([]byte(`{}`)))
	leaveRequest.Header.Set("Authorization", "Bearer "+firstToken)
	leaveResponse := httptest.NewRecorder()
	mux.ServeHTTP(leaveResponse, leaveRequest)
	if leaveResponse.Code != http.StatusNoContent {
		t.Fatalf("case-insensitive leave failed: %d %s", leaveResponse.Code, leaveResponse.Body.String())
	}
}

func TestCreateRoomRateLimit(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)

	for i := 0; i < 6; i++ {
		w := httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
		if w.Code != http.StatusCreated {
			t.Fatalf("create attempt %d: expected 201, got %d", i+1, w.Code)
		}
	}
	blocked := httptest.NewRecorder()
	mux.ServeHTTP(blocked, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	if blocked.Code != http.StatusTooManyRequests {
		t.Fatalf("expected rate limit 429, got %d", blocked.Code)
	}
}

func TestSignalRejectsUnauthorizedSenderAndFullQueue(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("POST /api/rooms/{code}/signal", s.sendSignal)

	created := httptest.NewRecorder()
	mux.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(created.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}

	join := func(id string) string {
		body, _ := json.Marshal(joinRequest{PeerID: id, Name: id, JoinPin: invite.JoinPin})
		request := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(body))
		response := httptest.NewRecorder()
		mux.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("join %s: %d %s", id, response.Code, response.Body.String())
		}
		var joined joinResponse
		if err := json.Unmarshal(response.Body.Bytes(), &joined); err != nil {
			t.Fatal(err)
		}
		return joined.PeerToken
	}
	from := "peer-alpha-123"
	to := "peer-bravo-123"
	fromToken := join(from)
	_ = join(to)

	body, _ := json.Marshal(Message{Type: "offer", From: from, To: to, Data: json.RawMessage(`{"sdp":"test"}`)})
	unauthorized := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/signal", bytes.NewReader(body))
	unauthorized.Header.Set("Authorization", "Bearer wrong-token")
	unauthorizedResponse := httptest.NewRecorder()
	mux.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusNotFound {
		t.Fatalf("expected unauthorized sender 404, got %d", unauthorizedResponse.Code)
	}

	target := s.rooms[invite.Code].Peers[to]
	for i := 0; i < cap(target.Events); i++ {
		target.Events <- Message{Type: "candidate", From: from, To: to}
	}
	full := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/signal", bytes.NewReader(body))
	full.Header.Set("Authorization", "Bearer "+fromToken)
	fullResponse := httptest.NewRecorder()
	mux.ServeHTTP(fullResponse, full)
	if fullResponse.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected queue-full 503, got %d", fullResponse.Code)
	}
	if got := len(target.Events); got != cap(target.Events) {
		t.Fatalf("full queue changed unexpectedly: len=%d cap=%d", got, cap(target.Events))
	}
}

func TestJoinRejectsWrongPinAndUnknownJSONFields(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)

	created := httptest.NewRecorder()
	mux.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(created.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}

	wrongPIN := "000000"
	if invite.JoinPin == wrongPIN {
		wrongPIN = "000001"
	}
	wrongPinBody, _ := json.Marshal(joinRequest{PeerID: "peer-alpha-123", Name: "Alpha", JoinPin: wrongPIN})
	wrongPin := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(wrongPinBody))
	wrongPinResponse := httptest.NewRecorder()
	mux.ServeHTTP(wrongPinResponse, wrongPin)
	if wrongPinResponse.Code != http.StatusNotFound {
		t.Fatalf("expected invalid PIN 404, got %d", wrongPinResponse.Code)
	}

	unknownField := httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", strings.NewReader(`{"peerId":"peer-alpha-123","name":"Alpha","joinPin":"`+invite.JoinPin+`","unexpected":true}`))
	unknownResponse := httptest.NewRecorder()
	mux.ServeHTTP(unknownResponse, unknownField)
	if unknownResponse.Code != http.StatusBadRequest {
		t.Fatalf("expected unknown-field 400, got %d", unknownResponse.Code)
	}
}

func TestPollEventsRequiresPeerToken(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("GET /api/rooms/{code}/events", s.pollEvents)

	created := httptest.NewRecorder()
	mux.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(created.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(joinRequest{PeerID: "peer-alpha-123", Name: "Alpha", JoinPin: invite.JoinPin})
	joined := httptest.NewRecorder()
	mux.ServeHTTP(joined, httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(body)))
	if joined.Code != http.StatusOK {
		t.Fatalf("join failed: %d", joined.Code)
	}

	bad := httptest.NewRequest(http.MethodGet, "/api/rooms/"+invite.Code+"/events?peerId=peer-alpha-123", nil)
	badResponse := httptest.NewRecorder()
	mux.ServeHTTP(badResponse, bad)
	if badResponse.Code != http.StatusNotFound {
		t.Fatalf("expected unauthorized poll 404, got %d", badResponse.Code)
	}
}

func TestDecodeJSONRejectsOversizedBody(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	large := strings.NewReader(`{"peerId":"` + strings.Repeat("a", maxBody) + `","name":"x","joinPin":"000000"}`)
	request := httptest.NewRequest(http.MethodPost, "/api/rooms/ABCDEFGH/join", large)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected oversized body 400, got %d", response.Code)
	}
}

func TestJoinRejectsWhenExistingPeerQueueIsFull(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)

	created := httptest.NewRecorder()
	mux.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(created.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(joinRequest{PeerID: "peer-alpha-123", Name: "Alpha", JoinPin: invite.JoinPin})
	joined := httptest.NewRecorder()
	mux.ServeHTTP(joined, httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(body)))
	if joined.Code != http.StatusOK {
		t.Fatalf("first join failed: %d %s", joined.Code, joined.Body.String())
	}

	peer := s.rooms[invite.Code].Peers["peer-alpha-123"]
	for i := 0; i < cap(peer.Events); i++ {
		peer.Events <- Message{Type: "candidate"}
	}
	secondBody, _ := json.Marshal(joinRequest{PeerID: "peer-bravo-123", Name: "Bravo", JoinPin: invite.JoinPin})
	second := httptest.NewRecorder()
	mux.ServeHTTP(second, httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(secondBody)))
	if second.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected queue-full join 503, got %d", second.Code)
	}
	if got := len(s.rooms[invite.Code].Peers); got != 1 {
		t.Fatalf("failed join must not leave a ghost peer in room; got %d peers", got)
	}
}

func TestCleanupRemovesExpiredRoomsAndRateEntries(t *testing.T) {
	s := newServer()
	s.rooms["ABCDEFGH"] = &Room{Code: "ABCDEFGH", ExpiresAt: time.Now().Add(-time.Minute), Peers: map[string]*Peer{}}
	s.joinRate["192.0.2.1"] = rateLimitEntry{count: 1, resetAt: time.Now().Add(-time.Minute)}
	s.createRate["192.0.2.2"] = rateLimitEntry{count: 1, resetAt: time.Now().Add(-time.Minute)}
	s.cleanupLocked()
	if s.rooms["ABCDEFGH"] != nil {
		t.Fatal("expired room was not removed")
	}
	if _, ok := s.joinRate["192.0.2.1"]; ok {
		t.Fatal("expired join rate entry was not removed")
	}
	if _, ok := s.createRate["192.0.2.2"]; ok {
		t.Fatal("expired create rate entry was not removed")
	}
}

func TestCreateRoomRejectsAtGlobalRoomLimit(t *testing.T) {
	s := newServer()
	for i := 0; i < maxActiveRooms; i++ {
		code := randomTestRoomCode(i)
		s.rooms[code] = &Room{Code: code, ExpiresAt: time.Now().Add(roomTTL), Peers: make(map[string]*Peer)}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	request := httptest.NewRequest(http.MethodPost, "/api/rooms", nil)
	request.RemoteAddr = "192.0.2.50:12345"
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected global room limit 503, got %d: %s", response.Code, response.Body.String())
	}
	if got := len(s.rooms); got != maxActiveRooms {
		t.Fatalf("room count changed despite rejected create: %d", got)
	}
}

func TestPollEventsAllowsOnlyOneLongPollPerPeer(t *testing.T) {
	s := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/rooms", s.createRoom)
	mux.HandleFunc("POST /api/rooms/{code}/join", s.joinRoom)
	mux.HandleFunc("GET /api/rooms/{code}/events", s.pollEvents)

	created := httptest.NewRecorder()
	mux.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/api/rooms", nil))
	var invite createRoomResponse
	if err := json.Unmarshal(created.Body.Bytes(), &invite); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(joinRequest{PeerID: "peer-alpha-123", Name: "Alpha", JoinPin: invite.JoinPin})
	joined := httptest.NewRecorder()
	mux.ServeHTTP(joined, httptest.NewRequest(http.MethodPost, "/api/rooms/"+invite.Code+"/join", bytes.NewReader(body)))
	var join joinResponse
	if err := json.Unmarshal(joined.Body.Bytes(), &join); err != nil {
		t.Fatal(err)
	}

	firstRequest := httptest.NewRequest(http.MethodGet, "/api/rooms/"+invite.Code+"/events?peerId=peer-alpha-123", nil)
	firstRequest.Header.Set("Authorization", "Bearer "+join.PeerToken)
	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		mux.ServeHTTP(httptest.NewRecorder(), firstRequest)
	}()

	peer := s.rooms[invite.Code].Peers["peer-alpha-123"]
	deadline := time.Now().Add(time.Second)
	for len(peer.PollSlots) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(peer.PollSlots) != 1 {
		t.Fatal("first long poll did not acquire the peer poll slot")
	}

	secondRequest := httptest.NewRequest(http.MethodGet, "/api/rooms/"+invite.Code+"/events?peerId=peer-alpha-123", nil)
	secondRequest.Header.Set("Authorization", "Bearer "+join.PeerToken)
	secondResponse := httptest.NewRecorder()
	mux.ServeHTTP(secondResponse, secondRequest)
	if secondResponse.Code != http.StatusConflict {
		t.Fatalf("expected duplicate long poll 409, got %d", secondResponse.Code)
	}

	peer.Events <- Message{Type: "test-wakeup"}
	select {
	case <-firstDone:
	case <-time.After(time.Second):
		t.Fatal("first long poll did not finish after an event arrived")
	}
}

func TestRateLimitTableRemainsBounded(t *testing.T) {
	bucket := make(map[string]rateLimitEntry, maxRateEntries)
	for i := 0; i < maxRateEntries; i++ {
		bucket[strings.Repeat("x", i%10)+"-"+time.Unix(int64(i), 0).Format("150405.000000000")] = rateLimitEntry{
			count: 1, resetAt: time.Now().Add(time.Hour),
		}
	}
	s := newServer()
	if s.allowAttempt("new-client", bucket, 6) {
		t.Fatal("new client should be rejected when the active rate table is full")
	}
	if got := len(bucket); got > maxRateEntries {
		t.Fatalf("rate table grew beyond the configured cap: %d", got)
	}
}

func randomTestRoomCode(index int) string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	value := index
	code := make([]byte, 8)
	for i := range code {
		code[i] = alphabet[value%len(alphabet)]
		value = value/len(alphabet) + 1
	}
	return string(code)
}


func TestCleanupKeepsNewEmptyInvitationRoom(t *testing.T) {
	server := newServer()
	room := &Room{
		Code: "ABCDEFGH", JoinPin: "123456", ExpiresAt: time.Now().Add(roomTTL),
		Peers: make(map[string]*Peer),
	}
	server.rooms[room.Code] = room

	server.mu.Lock()
	server.cleanupLocked()
	server.mu.Unlock()

	if server.rooms[room.Code] != room {
		t.Fatal("new empty invitation room must remain available until expiration")
	}
}

func TestCleanupRemovesIdlePeerAndNotifiesRemainingPeers(t *testing.T) {
	now := time.Now()
	server := newServer()
	staleDone := make(chan struct{})
	liveDone := make(chan struct{})
	stale := &Peer{
		ID: "peer-stale-123", Events: make(chan Message, maxQueue),
		PollSlots: make(chan struct{}, 1), Token: "stale-token",
		LastSeen: now.Add(-peerIdleTTL - time.Second), Done: staleDone,
	}
	live := &Peer{
		ID: "peer-live-123", Events: make(chan Message, maxQueue),
		PollSlots: make(chan struct{}, 1), Token: "live-token",
		LastSeen: now, Done: liveDone,
	}
	room := &Room{
		Code: "ABCDEFGH", JoinPin: "123456", ExpiresAt: now.Add(roomTTL),
		Peers: map[string]*Peer{stale.ID: stale, live.ID: live},
	}
	server.rooms[room.Code] = room

	server.mu.Lock()
	server.cleanupLocked()
	server.mu.Unlock()

	if room.Peers[stale.ID] != nil {
		t.Fatal("idle peer should be removed")
	}
	if room.Peers[live.ID] == nil {
		t.Fatal("active peer should remain in the room")
	}
	select {
	case <-staleDone:
	default:
		t.Fatal("removed peer's long-poll should be released")
	}
	select {
	case event := <-live.Events:
		if event.Type != "peer-left" || event.PeerID != stale.ID {
			t.Fatalf("unexpected peer-left event: %#v", event)
		}
	default:
		t.Fatal("remaining peer should receive a peer-left event")
	}
}

func TestCleanupExpiresRoomAndReleasesAllPollers(t *testing.T) {
	server := newServer()
	doneA := make(chan struct{})
	doneB := make(chan struct{})
	room := &Room{
		Code: "ABCDEFGH", JoinPin: "123456", ExpiresAt: time.Now().Add(-time.Second),
		Peers: map[string]*Peer{
			"peer-alpha-123": {ID: "peer-alpha-123", Done: doneA},
			"peer-bravo-123": {ID: "peer-bravo-123", Done: doneB},
		},
	}
	server.rooms[room.Code] = room

	server.mu.Lock()
	server.cleanupLocked()
	server.mu.Unlock()

	if server.rooms[room.Code] != nil {
		t.Fatal("expired room should be removed")
	}
	for name, done := range map[string]<-chan struct{}{"alpha": doneA, "bravo": doneB} {
		select {
		case <-done:
		default:
			t.Fatalf("%s peer long-poll was not released", name)
		}
	}
}
