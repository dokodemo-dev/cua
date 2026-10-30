// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"context"
	"net/http"
	"sync"
)

// SpaceState is what the browser needs to know about the Space behind a Bot.
type SpaceState struct {
	SpaceID string `json:"spaceID"`
	State   string `json:"state"` // pending, ready, failed
	Detail  string `json:"detail,omitempty"`
}

// Provisioner makes a Space exist for a Bot, so that creating a Bot is enough
// to start talking to it. It runs in the background: building a Space takes a
// minute or more, longer than a browser request should wait.
type Provisioner func(ctx context.Context, botID, spaceID string) error

type spaceStates struct {
	mu sync.Mutex
	m  map[string]SpaceState
}

func (s *spaceStates) set(botID string, state SpaceState) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.m == nil {
		s.m = map[string]SpaceState{}
	}
	s.m[botID] = state
}

func (s *spaceStates) get(botID string) (SpaceState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.m[botID]
	return state, ok
}

// startProvisioning remembers that the Space is being built and starts it.
func (s *Service) startProvisioning(botID, spaceID string) {
	s.spaces.set(botID, SpaceState{SpaceID: spaceID, State: "pending"})
	go func() {
		if err := s.Provisioner(context.Background(), botID, spaceID); err != nil {
			s.spaces.set(botID, SpaceState{SpaceID: spaceID, State: "failed", Detail: err.Error()})
			return
		}
		s.spaces.set(botID, SpaceState{SpaceID: spaceID, State: "ready"})
	}()
}

// SpaceOf is the Space a Bot lives in, or "" when it is not registered.
func (s *Service) SpaceOf(botID string) string {
	if state, ok := s.spaces.get(botID); ok && state.SpaceID != "" {
		return state.SpaceID
	}
	if binding, ok := bindingOf(s.registry, botID); ok {
		return binding.SpaceID
	}
	return ""
}

// space answers GET /v1/bots/<id>/space. A Bot with no recorded state reads as
// ready: it was registered by hand, so its Space is the operator's business.
func (s *Service) space(botID string) (int, any) {
	if state, ok := s.spaces.get(botID); ok {
		return http.StatusOK, state
	}
	if binding, ok := bindingOf(s.registry, botID); ok {
		return http.StatusOK, SpaceState{SpaceID: binding.SpaceID, State: "ready"}
	}
	return http.StatusNotFound, map[string]string{"error": "unknown bot"}
}
