// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// CreateBotResult is what the caller needs after creating a Bot.
type CreateBotResult struct {
	BotID      string
	SpaceID    string
	Credential string
	// CreateSpace says the caller asked for the Space to be built, so an
	// existing Space is never rebuilt by accident.
	CreateSpace bool
}

type createBotBody struct {
	BotID      string `json:"botID"`
	SpaceID    string `json:"spaceID"`
	TrustGroup string `json:"trustGroup"`
	// CreateSpace is set when the Browser picked "new Space" rather than an
	// existing one.
	CreateSpace bool `json:"createSpace"`
}

// CreateBot registers a Bot in a Space and returns its credential once. It is
// the API form of `--seed-bots`, so a Bot can be made from the browser instead
// of the shell. Only a registry administrator may call it, and that
// administrator must belong to no Space, so a Bot cannot create Bots.
func (s *Service) CreateBot(adminToken string, body []byte, now time.Time) (CreateBotResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	admin := s.tokens.Authenticate(adminToken, now)
	if admin == nil || !admin.Has(domain.CapManageRegistry) {
		return CreateBotResult{}, domain.ErrMissingCapability
	}
	for _, b := range s.registry.Bindings {
		if _, ok := b.Workspaces[admin.BotID]; ok {
			return CreateBotResult{}, domain.ErrMissingCapability
		}
	}
	var in createBotBody
	if err := json.Unmarshal(body, &in); err != nil {
		return CreateBotResult{}, domain.ErrInvalidIdentity
	}
	botID := strings.TrimSpace(in.BotID)
	spaceID := strings.TrimSpace(in.SpaceID)
	trust := strings.TrimSpace(in.TrustGroup)
	if trust == "" {
		// A Bot can only join a Space through that Space's own trust group. The
		// browser picks a Space by name and never sees the group, so inherit it
		// instead of failing with "trust group mismatch" for an existing Space.
		if binding, ok := s.registry.Bindings[spaceID]; ok {
			trust = binding.Group()
		} else {
			trust = "default"
		}
	}
	if botID == "" || !domain.ValidAgentName(botID) || spaceID == "" {
		return CreateBotResult{}, domain.ErrInvalidIdentity
	}
	if err := s.registry.AddTarget(domain.ExecutionTarget{
		ID: "local", Name: "This machine", Kind: domain.KindLocal,
	}); err != nil && err != domain.ErrDuplicateTarget {
		return CreateBotResult{}, err
	}
	if _, ok := s.registry.Bindings[spaceID]; !ok {
		if err := s.registry.AddBinding(domain.SpaceBinding{
			SpaceID: spaceID, TargetID: "local", Mode: domain.ModeShared,
			TrustGroup: trust, Workspaces: map[string]string{},
		}); err != nil {
			return CreateBotResult{}, err
		}
	}
	if err := s.registry.Assign(botID, spaceID, "/home/cua/bots/"+botID, trust); err != nil {
		return CreateBotResult{}, err
	}
	if err := s.registry.SetAvatar(botID, domain.DefaultAvatar(botID)); err != nil {
		return CreateBotResult{}, err
	}
	s.collab.Registry = s.registry

	lifetime := s.TokenLifetime
	if lifetime <= 0 {
		lifetime = 24 * time.Hour
	}
	space := spaceID
	issued, err := s.tokens.Issue(botID, trust, &space, domain.BotCapabilities, now, lifetime)
	if err != nil {
		return CreateBotResult{}, err
	}
	return CreateBotResult{
		BotID: botID, SpaceID: spaceID, Credential: issued, CreateSpace: in.CreateSpace,
	}, nil
}

// createBot answers POST /v1/manage/bots.
func (s *Service) createBot(adminToken string, body []byte, now time.Time) (int, any) {
	result, err := s.CreateBot(adminToken, body, now)
	switch {
	case err == nil:
	case err == domain.ErrMissingCapability:
		return http.StatusForbidden, map[string]string{"error": err.Error()}
	case err == domain.ErrInvalidIdentity:
		return http.StatusBadRequest, map[string]string{
			"error": "bot id must be 1-63 of a-z, 0-9, dot, underscore or hyphen; space id is required",
		}
	default:
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	if s.SecretDir != "" {
		_ = writeSecret(s.SecretDir, result.BotID+".token", result.Credential)
	}
	if s.Provisioner != nil && result.CreateSpace {
		s.startProvisioning(result.BotID, result.SpaceID)
	}
	return http.StatusCreated, map[string]string{
		"botID": result.BotID, "spaceID": result.SpaceID, "credential": result.Credential,
	}
}
