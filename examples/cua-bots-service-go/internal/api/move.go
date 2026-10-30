// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

type moveBotBody struct {
	SpaceID     string `json:"spaceID"`
	CreateSpace bool   `json:"createSpace"`
}

// moveBot answers POST /v1/manage/bots/<id>/space: a Bot can be pointed at the
// Space it really runs in. Without this the registry can claim one Space while
// the turns run in another, which is how a Bot ends up talking to nothing.
func (s *Service) moveBot(botID, adminToken string, body []byte, now time.Time) (int, any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	admin := s.tokens.Authenticate(adminToken, now)
	if admin == nil || !admin.Has(domain.CapManageRegistry) {
		return http.StatusForbidden, map[string]string{"error": "only an administrator can move a bot"}
	}
	var in moveBotBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	spaceID := strings.TrimSpace(in.SpaceID)
	if spaceID == "" {
		return http.StatusBadRequest, map[string]string{"error": "spaceID is required"}
	}
	if _, known := bindingOf(s.registry, botID); !known {
		return http.StatusNotFound, map[string]string{"error": "unknown bot"}
	}
	if err := s.registry.AddTarget(domain.ExecutionTarget{
		ID: "local", Name: "This machine", Kind: domain.KindLocal,
	}); err != nil && err != domain.ErrDuplicateTarget {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	if _, ok := s.registry.Bindings[spaceID]; !ok {
		trust := "default"
		if binding, ok := bindingOf(s.registry, botID); ok {
			trust = binding.Group()
		}
		if err := s.registry.AddBinding(domain.SpaceBinding{
			SpaceID: spaceID, TargetID: "local", Mode: domain.ModeShared,
			TrustGroup: trust, Workspaces: map[string]string{},
		}); err != nil {
			return statusFor(err), map[string]string{"error": err.Error()}
		}
	}
	if err := s.registry.Move(botID, spaceID); err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	s.collab.Registry = s.registry
	if s.Provisioner != nil && in.CreateSpace {
		s.startProvisioning(botID, spaceID)
	}
	// A run started in the old Space cannot be continued in the new one; the
	// turn runner keys its state by Space, so nothing else has to be reset.
	return http.StatusOK, map[string]string{"bot": botID, "spaceID": spaceID}
}
