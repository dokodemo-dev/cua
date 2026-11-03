// SPDX-License-Identifier: FSL-1.1-MIT

// Package api is the HTTP surface: the same paths, status codes and refusals the
// Swift build exposes, so a Pi extension or CLI works against either.
package api

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// Persister saves state after a successful mutation.
type Persister interface {
	Save(State) error
}

// State is the whole persisted service state; the JSON shape matches the Swift
// build so a file can move between them.
type State struct {
	Version       int                          `json:"version"`
	Registry      domain.Registry              `json:"registry"`
	Tokens        domain.TokenStore            `json:"tokens"`
	Collaboration domain.CollaborationSnapshot `json:"collaboration"`
	// Turns is the browser's chat history per Bot.
	Turns map[string][]Turn `json:"turns,omitempty"`
	// Pins is the operator's sidebar order, newest first. It is a UI
	// preference rather than execution state, but it lives here so every
	// device that opens the page sees the same pins.
	Pins []string `json:"pins,omitempty"`
	// Agents is per-Bot agent settings. A Bot without an entry follows the
	// host-wide defaults in turn.env.
	Agents map[string]AgentSettings `json:"agents,omitempty"`
}

// Service routes requests. All state is guarded by one mutex: the service is
// small and serialization is what keeps claims honest.
type Service struct {
	mu       sync.Mutex
	registry domain.Registry
	tokens   domain.TokenStore
	collab   *domain.Collaboration
	store    Persister
	now      func() time.Time
	pins     []string
	agents   map[string]AgentSettings
	limiter  *limiter
	// BodyLimit caps request bodies (bytes); RateLimit caps requests per minute.
	BodyLimit int
	RateLimit int
	// AllowRemote turns off the loopback check for a VPN-bound listener.
	AllowRemote bool
	// SpaceLister reports the Spaces a Bot could be put in, when set.
	SpaceLister SpaceLister
	// Provisioner builds the Space for a newly created Bot, when set.
	Provisioner Provisioner
	spaces      spaceStates
	// SecretDir is where a created Bot's credential is copied (0600).
	SecretDir string
	// RunsDir is where cua-bot-turn keeps one run id per Bot and Space. A
	// settings change deletes them so the next turn starts a new run.
	RunsDir string
	// KeysPath is the provider-key file the Web UI writes (0600). Empty
	// disables the key screen.
	KeysPath string
	// SchedulerDir is where the scheduler keeps scheduler.json.
	SchedulerDir string
	// Schedule writes that file under the same lock the scheduler uses, so a
	// routine added from the browser cannot race a delivery.
	Schedule ScheduleStore
	// TokenLifetime is how long a credential issued through the API lives.
	TokenLifetime time.Duration
	// OnDenied reports refusals without the token value.
	OnDenied func(status int, path string)
	// codes are the one-time login codes a browser link carries.
	codes *loginCodes
	// chat is the browser window over Bot turns.
	chat *Chat
}

// New builds a service over the given state.
func New(st State, store Persister) *Service {
	if st.Registry.Targets == nil || st.Registry.Bindings == nil {
		st.Registry = domain.NewRegistry()
	}
	if st.Tokens.Entries == nil {
		st.Tokens = domain.NewTokenStore()
	}
	if st.Collaboration.Stored == nil {
		st.Collaboration = domain.NewCollaboration(st.Registry).State
	}
	s := &Service{
		registry: st.Registry,
		tokens:   st.Tokens,
		store:    store,
		now:      time.Now,
		// A browser polls once a second and adds a few reads per screen; 60 a
		// minute locked the operator out of their own window.
		limiter:   newLimiter(600),
		BodyLimit: 64 * 1024,
		RateLimit: 600,
	}
	s.codes = newLoginCodes(func() time.Time { return s.now() })
	s.pins = append([]string(nil), st.Pins...)
	s.agents = map[string]AgentSettings{}
	for id, settings := range st.Agents {
		s.agents[id] = settings
	}
	s.chat = NewChat(nil, nil)
	s.chat.Restore(st.Turns)
	s.chat.SetOnFinish(func() { _ = s.Save() })
	s.collab = domain.NewCollaboration(s.registry)
	s.collab.State = st.Collaboration
	return s
}

// Snapshot returns the state to persist.
func (s *Service) Snapshot() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	return State{Version: 1, Registry: s.registry, Tokens: s.tokens,
		Collaboration: s.collab.State, Turns: s.chat.Snapshot(),
		Pins: append([]string(nil), s.pins...), Agents: s.agentsCopyLocked()}
}

// SetTurnRunner installs what runs a chat turn (cua-bot-turn in production).
func (s *Service) SetTurnRunner(runner TurnRunner) {
	turns := s.chat.Snapshot()
	s.chat = NewChat(runner, s.now)
	s.chat.Restore(turns)
	s.chat.SetOnFinish(func() { _ = s.Save() })
}

// SetClock is for tests.
func (s *Service) SetClock(f func() time.Time) { s.now = f }

// Tokens exposes the store for issuing credentials at startup and by CLI.
func (s *Service) Tokens() *domain.TokenStore { return &s.tokens }

// Registry exposes the registry for setup code.
func (s *Service) Registry() *domain.Registry { return &s.registry }

// Sync lets a caller rebuild the collaboration view after changing the registry.
func (s *Service) Sync() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.collab.Registry = s.registry
}

// Save persists the current state.
func (s *Service) Save() error {
	if s.store == nil {
		return nil
	}
	return s.store.Save(s.Snapshot())
}

func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	now := s.now()
	if !s.remoteAllowed(r) {
		s.deny(w, http.StatusForbidden, "management API is local only", r)
		return
	}
	if s.uiAsset(w, r) {
		return
	}
	// The page owns everything under /ui: /ui/<bot>/<tab> and
	// /ui/settings/<section> are states of the same single page, so they all
	// return it (the assets are served above).
	if r.URL.Path == "/ui" || strings.HasPrefix(r.URL.Path, "/ui/") {
		// /ui?login=<credential> stores it as a session cookie, so a link can
		// open a browser that is already signed in and the token never has to
		// be pasted into a field.
		if r.URL.Query().Get("logout") != "" {
			clearSessionCookie(w, r)
			w.Header().Set("Location", "/ui")
			w.WriteHeader(http.StatusSeeOther)
			return
		}
		if code := strings.TrimSpace(r.URL.Query().Get("login")); code != "" {
			if s.tokens.Authenticate(code, now) == nil {
				w.Header().Set("Location", r.URL.Path+"?login=failed")
				w.WriteHeader(http.StatusSeeOther)
				return
			}
			// Sign in with a page rather than a redirect: a redirect can lose
			// its fragment, and a browser that will not keep our cookie would
			// then look signed out. The same value is stored by the page itself.
			s.setSessionCookie(w, r, code, now)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			securityHeaders(w, "")
			// The inline script stores the credential and moves on; it carries a
			// nonce so the page's policy can allow exactly that script.
			nonce := newNonce()
			w.Header().Set("Content-Security-Policy",
				"default-src 'none'; script-src 'nonce-"+nonce+"'; "+
					"style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; "+
					"frame-ancestors 'none'")
			_, _ = w.Write(loginPage(code, r.URL.Path, nonce))
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		// A cached copy of an older page cannot know about a newer sign-in
		// route, which looks exactly like a broken session.
		w.Header().Set("Cache-Control", "no-store")
		securityHeaders(w, appCSP)
		_, _ = w.Write(chatPage)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, int64(s.BodyLimit)+1))
	if err != nil {
		s.deny(w, http.StatusBadRequest, "unreadable body", r)
		return
	}
	if len(body) > s.BodyLimit {
		s.deny(w, http.StatusRequestEntityTooLarge, "request body too large", r)
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/v1/login/exchange" {
		status, payload := s.exchangeLogin(w, r, body, now)
		if status == http.StatusNoContent {
			w.WriteHeader(status)
			return
		}
		writeJSON(w, status, payload)
		return
	}
	token := bearer(r)
	if token == "" {
		if c, err := r.Cookie(sessionCookieName); err == nil {
			token = strings.TrimSpace(c.Value)
		}
	}
	// The health probe needs no token and no budget: a monitor should not be
	// rate-limited into silence.
	if r.URL.Path == "/v1/health" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	if token != "" && !s.limiter.allow(token, now) {
		s.deny(w, http.StatusTooManyRequests, "too many requests", r)
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/v1/login/code" {
		status, payload := s.issueLoginCode(token)
		writeJSON(w, status, payload)
		return
	}
	mutating := r.Method != http.MethodGet
	status, payload := s.route(r, token, body, now)
	if mutating && status < 400 {
		_ = s.Save()
	}
	if status >= 400 {
		if s.OnDenied != nil {
			s.OnDenied(status, r.URL.Path)
		}
	}
	writeJSON(w, status, payload)
}

func (s *Service) route(r *http.Request, token string, body []byte, now time.Time) (int, any) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) >= 5 && parts[0] == "v1" && parts[1] == "manage" && parts[2] == "bots" &&
		parts[4] == "token" && r.Method == http.MethodPost {
		return s.mint(parts[3], token, now)
	}
	if len(parts) == 5 && parts[0] == "v1" && parts[1] == "manage" && parts[2] == "bots" &&
		parts[4] == "space" && r.Method == http.MethodPost {
		return s.moveBot(parts[3], token, body, now)
	}
	if len(parts) == 5 && parts[0] == "v1" && parts[1] == "manage" && parts[2] == "bots" &&
		parts[4] == "avatar" && r.Method == http.MethodPost {
		return s.setAvatar(parts[3], token, body, now)
	}
	if len(parts) == 5 && parts[0] == "v1" && parts[1] == "manage" && parts[2] == "bots" &&
		(parts[4] == "archive" || parts[4] == "unarchive") && r.Method == http.MethodPost {
		return s.archiveBot(parts[3], token, parts[4] == "unarchive", now)
	}
	if len(parts) == 3 && parts[0] == "v1" && parts[1] == "manage" && parts[2] == "bots" &&
		r.Method == http.MethodPost {
		return s.createBot(token, body, now)
	}
	if len(parts) == 2 && parts[0] == "v1" && parts[1] == "session" && r.Method == http.MethodGet {
		return s.sessionInfo(token, now)
	}
	if len(parts) >= 2 && parts[0] == "v1" && parts[1] == "keys" {
		if token == "" {
			return http.StatusUnauthorized, map[string]string{"error": "missing token"}
		}
		p := s.tokens.Authenticate(token, now)
		if p == nil {
			return http.StatusUnauthorized, map[string]string{"error": "invalid token"}
		}
		admin := p.Has(domain.CapManageRegistry)
		if len(parts) == 2 && r.Method == http.MethodGet {
			return s.listKeys(admin)
		}
		if len(parts) == 3 && (r.Method == http.MethodPut || r.Method == http.MethodDelete) {
			if r.Method == http.MethodDelete {
				return s.deleteKey(parts[2], admin)
			}
			return s.putKey(parts[2], body, admin, now)
		}
		return http.StatusNotFound, map[string]string{"error": "unknown path"}
	}
	if len(parts) == 2 && parts[0] == "v1" && parts[1] == "spaces" && r.Method == http.MethodGet {
		return s.spacesList(token, now)
	}
	if len(parts) == 2 && parts[0] == "v1" && parts[1] == "bots" && r.Method == http.MethodGet {
		return s.listBots(token, now, r.URL.Query().Has("archived"))
	}
	if len(parts) == 2 && parts[0] == "v1" && parts[1] == "pins" && r.Method == http.MethodGet {
		return s.listPins(token, now)
	}
	if len(parts) == 3 && parts[0] == "v1" && parts[1] == "pins" &&
		(r.Method == http.MethodPut || r.Method == http.MethodDelete) {
		return s.changePin(parts[2], token, now, r.Method == http.MethodPut)
	}
	if len(parts) < 4 || parts[0] != "v1" || parts[1] != "bots" {
		return http.StatusNotFound, map[string]string{"error": "unknown path"}
	}
	botID := parts[2]
	if token == "" {
		return http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return http.StatusUnauthorized, map[string]string{"error": "invalid token"}
	}
	if s.registry.IsArchived(botID) {
		return http.StatusConflict, map[string]string{"error": "this bot is archived; put it back before using it"}
	}
	// A registry administrator may drive any Bot from the browser. That is not
	// an escalation: the same credential can already mint a token for any Bot.
	if p.BotID != botID && !p.Has(domain.CapManageRegistry) {
		return http.StatusForbidden, map[string]string{"error": "token is for another bot"}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.collab.Registry = s.registry
	switch {
	case r.Method == http.MethodGet && len(parts) == 4 && parts[3] == "messages":
		return s.listMessages(*p, now)
	case r.Method == http.MethodPost && len(parts) == 4 && parts[3] == "messages":
		return s.postMessage(*p, body, now)
	case r.Method == http.MethodPost && len(parts) == 4 && parts[3] == "delegate":
		return s.delegate(*p, body, now)
	case len(parts) == 4 && parts[3] == "agent" && r.Method == http.MethodGet:
		return s.getAgent(botID, now)
	case len(parts) == 4 && parts[3] == "agent" && r.Method == http.MethodPut:
		return s.putAgent(botID, body, p.Has(domain.CapManageRegistry))
	case len(parts) == 5 && parts[3] == "agent" && parts[4] == "env" && r.Method == http.MethodGet:
		return s.agentEnvFor(botID, now)
	case len(parts) == 4 && parts[3] == "artifacts" && r.Method == http.MethodGet:
		return s.listArtifacts(botID)
	case r.Method == http.MethodPost && len(parts) == 4 && parts[3] == "artifacts":
		return s.artifact(*p, body, now)
	case len(parts) == 4 && parts[3] == "chat":
		return s.chatRoute(botID, r, body)
	case len(parts) == 4 && parts[3] == "routines" && r.Method == http.MethodGet:
		return s.routines(botID)
	case len(parts) == 4 && parts[3] == "routines" && r.Method == http.MethodPost:
		return s.addRoutine(botID, body, now)
	case len(parts) == 6 && parts[3] == "routines" && r.Method == http.MethodPost &&
		(parts[5] == "pause" || parts[5] == "resume"):
		return s.changeRoutine(botID, parts[4], parts[5] == "pause")
	case len(parts) == 5 && parts[3] == "routines" && r.Method == http.MethodDelete:
		return s.removeRoutine(botID, parts[4])
	case len(parts) == 4 && parts[3] == "space" && r.Method == http.MethodGet:
		return s.space(botID)
	case len(parts) == 5 && parts[3] == "chat" && parts[4] == "record" &&
		r.Method == http.MethodPost:
		return s.chatRecord(botID, body)
	default:
		return http.StatusNotFound, map[string]string{"error": "unknown path"}
	}
}

type messageBody struct {
	SpaceID        string  `json:"spaceID"`
	Body           string  `json:"body"`
	To             *string `json:"to"`
	IdempotencyKey string  `json:"idempotencyKey"`
}

type delegateBody struct {
	To              string  `json:"to"`
	SpaceID         string  `json:"spaceID"`
	Prompt          string  `json:"prompt"`
	IdempotencyKey  string  `json:"idempotencyKey"`
	DeadlineSeconds float64 `json:"deadlineSeconds"`
	ParentID        *string `json:"parentID"`
}

type artifactBody struct {
	SpaceID   string `json:"spaceID"`
	Name      string `json:"name"`
	ByteCount int64  `json:"byteCount"`
	Sha256    string `json:"sha256"`
}

func (s *Service) listMessages(p domain.Principal, now time.Time) (int, any) {
	if err := domain.Authorize(s.registry, p, p.SpaceID); err != nil {
		return http.StatusForbidden, map[string]string{"error": err.Error()}
	}
	messages := s.collab.Deliverable(p.BotID, now)
	rows := make([]map[string]string, 0, len(messages))
	for _, m := range messages {
		rows = append(rows, map[string]string{
			"id": m.ID, "sender": m.SenderBotID, "spaceID": m.SpaceID,
			"body": m.Body, "kind": string(m.Kind),
		})
	}
	return http.StatusOK, map[string]any{"messages": rows}
}

func (s *Service) postMessage(p domain.Principal, body []byte, now time.Time) (int, any) {
	var in messageBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	message, err := s.collab.Post(p, in.SpaceID, in.Body, in.To, in.IdempotencyKey, now)
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	return http.StatusCreated, map[string]string{"id": message.ID}
}

func (s *Service) delegate(p domain.Principal, body []byte, now time.Time) (int, any) {
	var in delegateBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	if in.DeadlineSeconds <= 0 || in.DeadlineSeconds > 1800 {
		return http.StatusBadRequest, map[string]string{"error": "invalid deadline"}
	}
	result, err := s.collab.Delegate(p, in.To, in.SpaceID, in.Prompt, in.IdempotencyKey,
		in.ParentID, now, now.Add(time.Duration(in.DeadlineSeconds)*time.Second))
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	status := http.StatusOK
	if result.Fresh {
		status = http.StatusCreated
	}
	return status, map[string]string{
		"id": result.Task.ID, "depth": strconv.Itoa(result.Task.Depth),
		"state": string(result.Task.State),
	}
}

// listArtifacts answers GET /v1/bots/<id>/artifacts with the references the Bot
// can see. The bytes stay in the Bot's Space; this is the index.
func (s *Service) listArtifacts(botID string) (int, any) {
	rows := s.collab.Artifacts(botID)
	newest := make([]domain.Artifact, 0, len(rows))
	for i := len(rows) - 1; i >= 0; i-- {
		newest = append(newest, rows[i])
	}
	return http.StatusOK, map[string]any{"artifacts": newest, "asOf": float64(s.now().Unix())}
}

func (s *Service) artifact(p domain.Principal, body []byte, now time.Time) (int, any) {
	var in artifactBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	artifact, err := s.collab.RegisterArtifact(p, in.SpaceID, in.Name, in.ByteCount, in.Sha256, now)
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	return http.StatusCreated, map[string]string{"id": artifact.ID}
}

// Mint issues a credential for one Bot: loopback, an admin token, and an admin
// that belongs to no Space (so a Bot token can never mint another).
func (s *Service) Mint(botID string, adminToken string, now time.Time) (string, time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	admin := s.tokens.Authenticate(adminToken, now)
	if admin == nil || !admin.Has(domain.CapManageRegistry) {
		return "", time.Time{}, domain.ErrMissingCapability
	}
	for _, b := range s.registry.Bindings {
		if _, ok := b.Workspaces[admin.BotID]; ok {
			return "", time.Time{}, domain.ErrMissingCapability
		}
	}
	binding, ok := bindingOf(s.registry, botID)
	if !ok {
		return "", time.Time{}, domain.ErrUnknownSpace
	}
	lifetime := s.TokenLifetime
	if lifetime <= 0 {
		lifetime = 24 * time.Hour
	}
	spaceID := binding.SpaceID
	value, err := s.tokens.Issue(botID, binding.Group(), &spaceID, domain.BotCapabilities, now, lifetime)
	if err != nil {
		return "", time.Time{}, err
	}
	return value, now.Add(lifetime), nil
}

func (s *Service) mint(botID, token string, now time.Time) (int, any) {
	value, expires, err := s.Mint(botID, token, now)
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	_ = s.Save()
	return http.StatusCreated, map[string]string{
		"value": value, "expiresIn": strconv.Itoa(int(expires.Sub(now).Seconds())),
	}
}

func bindingOf(r domain.Registry, botID string) (domain.SpaceBinding, bool) {
	for _, b := range r.Bindings {
		if _, ok := b.Workspaces[botID]; ok {
			return b, true
		}
	}
	return domain.SpaceBinding{}, false
}

func statusFor(err error) int {
	switch {
	case errors.Is(err, domain.ErrMissingCapability), errors.Is(err, domain.ErrNotAMember),
		errors.Is(err, domain.ErrCrossBotAccess), errors.Is(err, domain.ErrUnauthorized),
		errors.Is(err, domain.ErrCrossTrustGroup), errors.Is(err, domain.ErrSelfDelegation):
		return http.StatusForbidden
	case errors.Is(err, domain.ErrUnknownSpace), errors.Is(err, domain.ErrUnknownTarget):
		return http.StatusNotFound
	case errors.Is(err, domain.ErrArtifactTooLarge):
		return http.StatusRequestEntityTooLarge
	case errors.Is(err, domain.ErrIdempotencyConflict), errors.Is(err, domain.ErrTaskExpired),
		errors.Is(err, domain.ErrParentExpired), errors.Is(err, domain.ErrTaskNotRunning):
		return http.StatusConflict
	case errors.Is(err, domain.ErrDepthExceeded), errors.Is(err, domain.ErrConcurrencyLimit),
		errors.Is(err, domain.ErrDelegationLoop):
		return http.StatusTooManyRequests
	default:
		return http.StatusBadRequest
	}
}

func (s *Service) remoteAllowed(r *http.Request) bool {
	if s.AllowRemote {
		return true
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return host == "127.0.0.1" || host == "::1"
}

func (s *Service) deny(w http.ResponseWriter, status int, message string, r *http.Request) {
	if s.OnDenied != nil {
		s.OnDenied(status, r.URL.Path)
	}
	writeJSON(w, status, map[string]string{"error": message})
}

// sessionLifetime is how long the /ui?login= cookie lasts.
func (s *Service) sessionLifetime() time.Duration {
	if s.TokenLifetime > 0 {
		return s.TokenLifetime
	}
	return 24 * time.Hour
}

func bearer(r *http.Request) string {
	value := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(value, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, prefix))
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

type limiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	seen   map[string]windowCount
}

type windowCount struct {
	start time.Time
	count int
}

func newLimiter(limit int) *limiter {
	return &limiter{limit: limit, window: time.Minute, seen: map[string]windowCount{}}
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	window := l.seen[key]
	if now.Before(window.start.Add(l.window)) {
		if window.count >= l.limit {
			return false
		}
		window.count++
		l.seen[key] = window
		return true
	}
	l.seen[key] = windowCount{start: now, count: 1}
	return true
}
