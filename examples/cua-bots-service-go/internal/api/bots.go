// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"sort"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// listBots answers the Bot picker. A registry administrator sees every Bot; a
// Bot's own credential sees only itself, so the list never widens access.
// Archived Bots are listed apart, and only for an administrator.
func (s *Service) listBots(token string, now time.Time, includeArchived bool) (int, any) {
	if token == "" {
		return http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return http.StatusUnauthorized, map[string]string{"error": "invalid token"}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	admin := p.Has(domain.CapManageRegistry)
	var ids, archived []string
	if admin {
		for _, binding := range s.registry.Bindings {
			ids = append(ids, binding.BotIDs()...)
		}
	} else {
		ids = append(ids, p.BotID)
	}
	live := make([]string, 0, len(ids))
	for _, id := range ids {
		if !s.registry.IsArchived(id) {
			live = append(live, id)
			continue
		}
		if admin && includeArchived {
			archived = append(archived, id)
		}
	}
	sort.Strings(live)
	sort.Strings(archived)
	if archived == nil {
		archived = []string{}
	}
	avatars := map[string]domain.Avatar{}
	spaces := map[string]string{}
	// activity is when each Bot last started a turn, so the rail can sort by
	// "最後に動いた順" without asking per Bot. A Bot with no turns is absent.
	activity := map[string]float64{}
	for _, id := range append(append([]string{}, live...), archived...) {
		avatars[id] = s.registry.AvatarOf(id)
		if binding, ok := bindingOf(s.registry, id); ok {
			spaces[id] = binding.SpaceID
		}
		if at := s.chat.LastActive(id); at > 0 {
			activity[id] = at
		}
	}
	return http.StatusOK, map[string]any{
		"bots": live, "archived": archived, "avatars": avatars, "spaces": spaces,
		"activity": activity,
	}
}
