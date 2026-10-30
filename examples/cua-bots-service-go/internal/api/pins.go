// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"slices"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// maxPins bounds the sidebar row. The page shows a handful of large icons, so
// a longer list would only push the Bot list down.
const maxPins = 20

// pinsAdmin authenticates the caller and requires the registry capability.
// Pins are an operator preference, not something a Bot may change.
func (s *Service) pinsAdmin(token string, now time.Time) (*domain.Principal, int, any) {
	if token == "" {
		return nil, http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return nil, http.StatusUnauthorized, map[string]string{"error": "invalid token"}
	}
	if !p.Has(domain.CapManageRegistry) {
		return nil, http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	return p, 0, nil
}

// listPins answers GET /v1/pins with the ids in display order.
func (s *Service) listPins(token string, now time.Time) (int, any) {
	if _, status, payload := s.pinsAdmin(token, now); status != 0 {
		return status, payload
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return http.StatusOK, map[string]any{"bots": append([]string{}, s.pins...)}
}

// changePin answers PUT /v1/pins/<id> and DELETE /v1/pins/<id>. Pinning an
// already pinned Bot keeps its place, so a retry is harmless.
func (s *Service) changePin(botID, token string, now time.Time, pinned bool) (int, any) {
	if _, status, payload := s.pinsAdmin(token, now); status != 0 {
		return status, payload
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.registry.IsArchived(botID) {
		return http.StatusConflict, map[string]string{"error": "this bot is archived"}
	}
	if _, ok := bindingOf(s.registry, botID); !ok {
		return http.StatusNotFound, map[string]string{"error": "unknown bot"}
	}
	if pinned {
		if !slices.Contains(s.pins, botID) {
			s.pins = append([]string{botID}, s.pins...)
			if len(s.pins) > maxPins {
				s.pins = s.pins[:maxPins]
			}
		}
	} else {
		s.pins = slices.DeleteFunc(s.pins, func(id string) bool { return id == botID })
	}
	return http.StatusOK, map[string]any{"bots": append([]string{}, s.pins...)}
}
