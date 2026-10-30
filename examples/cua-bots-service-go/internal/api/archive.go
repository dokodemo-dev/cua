// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// archiveBot answers POST /v1/manage/bots/<id>/archive and .../unarchive.
//
// Archiving is the reversible choice: the Bot keeps its Space, workspace and
// history, its credentials stop working, and it disappears from the picker.
// Deleting would have to decide what to do with the Space and its files, which
// is a separate decision the operator has not made.
func (s *Service) archiveBot(botID, adminToken string, restore bool, now time.Time) (int, any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	admin := s.tokens.Authenticate(adminToken, now)
	if admin == nil || !admin.Has(domain.CapManageRegistry) {
		return http.StatusForbidden, map[string]string{"error": "only an administrator can archive"}
	}
	for _, b := range s.registry.Bindings {
		if _, ok := b.Workspaces[admin.BotID]; ok {
			return http.StatusForbidden, map[string]string{"error": "only an administrator can archive"}
		}
	}
	var err error
	if restore {
		err = s.registry.Unarchive(botID)
	} else {
		err = s.registry.Archive(botID)
	}
	if err != nil {
		return http.StatusNotFound, map[string]string{"error": "unknown bot"}
	}
	pausedRoutines := 0
	if s.Schedule != nil {
		// A routine outlives the token check: the scheduler runs cua-bot-turn
		// directly, so putting the Bot away has to stop its schedule too.
		if err := s.Schedule.Lock("service", func(state *domain.Scheduler) error {
			pausedRoutines = state.SetPausedForArchive(botID, !restore)
			return nil
		}); err != nil {
			return http.StatusServiceUnavailable, map[string]string{"error": err.Error()}
		}
	}
	if !restore {
		// A token that keeps working would let an archived Bot be driven from
		// a routine or a script, which is the opposite of putting it away.
		s.tokens.RevokeAll(botID, now)
	}
	return http.StatusOK, map[string]any{
		"bot": botID, "archived": !restore, "routinesChanged": pausedRoutines,
	}
}
