// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// setAvatar answers POST /v1/manage/bots/<id>/avatar.
func (s *Service) setAvatar(botID, token string, body []byte, now time.Time) (int, any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	// A Bot may restyle itself; an administrator may restyle any Bot.
	if p.BotID != botID && !p.Has(domain.CapManageRegistry) {
		return http.StatusForbidden, map[string]string{"error": "token is for another bot"}
	}
	var in domain.Avatar
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	if err := s.registry.SetAvatar(botID, in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "unknown bot or unknown value"}
	}
	return http.StatusOK, s.registry.AvatarOf(botID)
}
