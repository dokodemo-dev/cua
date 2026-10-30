// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"sort"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// sessionInfo answers GET /v1/session: who this browser is acting as, what it
// may do, and when it stops working. It never returns the credential itself, so
// the settings page can describe the session without handling a secret.
func (s *Service) sessionInfo(token string, now time.Time) (int, any) {
	if token == "" {
		return http.StatusUnauthorized, map[string]string{"error": "not signed in"}
	}
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return http.StatusUnauthorized, map[string]string{"error": "not signed in"}
	}
	caps := make([]string, 0, len(p.Capabilities))
	for c := range p.Capabilities {
		caps = append(caps, string(c))
	}
	sort.Strings(caps)
	expires := s.tokens.Expiry(token)
	role := "bot"
	if p.Has(domain.CapManageRegistry) {
		role = "administrator"
	}
	body := map[string]any{
		"role": role, "botID": p.BotID, "capabilities": caps,
	}
	if !expires.IsZero() {
		body["expiresAt"] = float64(expires.Unix())
	}
	if p.SpaceID != "" {
		body["spaceID"] = p.SpaceID
	}
	return http.StatusOK, body
}
