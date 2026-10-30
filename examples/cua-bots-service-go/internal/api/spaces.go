// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// SpaceInfo is one Space the host can put a Bot in.
type SpaceInfo struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Kind    string `json:"kind,omitempty"`
	Genesis string `json:"provider,omitempty"`
}

// SpaceLister reports the Spaces this host has. The browser needs it to offer
// "put this Bot in an existing Space" instead of asking for an id to type.
type SpaceLister func(ctx context.Context) ([]SpaceInfo, error)

// SpaceView is one Space as the settings screen needs it: the Space itself, the
// Bots that run in it, and whether cua still knows about it. A Bot can name a
// Space that was deleted (or never registered), and that is worth showing rather
// than hiding.
type SpaceView struct {
	SpaceInfo
	Registered bool     `json:"registered"`
	Bots       []string `json:"bots,omitempty"`
	State      string   `json:"state,omitempty"`
}

// spaceViews joins the host's Space list with the Bots bound to each Space.
// Bots' Spaces that the host does not list are included with Registered false.
func (s *Service) spaceViews(list []SpaceInfo) []SpaceView {
	byID := make(map[string]*SpaceView, len(list))
	out := make([]SpaceView, 0, len(list))
	for _, info := range list {
		view := SpaceView{SpaceInfo: info, Registered: true}
		byID[info.ID] = &view
		out = append(out, view)
	}
	bots := map[string][]string{}
	for _, binding := range s.registry.Bindings {
		for _, botID := range binding.BotIDs() {
			if binding.SpaceID == "" {
				continue
			}
			bots[binding.SpaceID] = append(bots[binding.SpaceID], botID)
		}
	}
	for spaceID := range bots {
		if _, ok := byID[spaceID]; ok {
			continue
		}
		// Keep the order stable: the caller sorts by id afterwards.
		name := spaceID
		if at := indexByte(spaceID, ':'); at >= 0 {
			name = spaceID[at+1:]
		}
		view := SpaceView{
			SpaceInfo:  SpaceInfo{ID: spaceID, Name: name},
			Registered: false,
		}
		byID[spaceID] = &view
		out = append(out, view)
	}
	for i := range out {
		ids := append([]string(nil), bots[out[i].ID]...)
		sort.Strings(ids)
		out[i].Bots = ids
		for _, botID := range ids {
			if state, ok := s.spaces.get(botID); ok && state.State != "" && state.State != "ready" {
				out[i].State = state.State
				break
			}
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].ID < out[b].ID })
	return out
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// spaces answers GET /v1/spaces for a registry administrator.
func (s *Service) spacesList(token string, now time.Time) (int, any) {
	p := s.tokens.Authenticate(token, now)
	if p == nil {
		return http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	if !p.Has(domain.CapManageRegistry) {
		return http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	if s.SpaceLister == nil {
		// Without the host list, the Bots still say where they run.
		s.mu.Lock()
		views := s.spaceViews(nil)
		s.mu.Unlock()
		return http.StatusOK, map[string]any{"spaces": views, "note": "not configured"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	list, err := s.SpaceLister(ctx)
	if err != nil {
		return http.StatusServiceUnavailable, map[string]string{"error": err.Error()}
	}
	s.mu.Lock()
	views := s.spaceViews(list)
	s.mu.Unlock()
	return http.StatusOK, map[string]any{"spaces": views}
}

// ParseSpaces reads `cua spaces ls --json`.
func ParseSpaces(data []byte) ([]SpaceInfo, error) {
	var payload struct {
		Spaces []struct {
			ID          string `json:"id"`
			DisplayName string `json:"display_name"`
			Kind        string `json:"kind"`
			Provider    string `json:"provider"`
		} `json:"spaces"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	out := make([]SpaceInfo, 0, len(payload.Spaces))
	for _, s := range payload.Spaces {
		out = append(out, SpaceInfo{ID: s.ID, Name: s.DisplayName, Kind: s.Kind, Genesis: s.Provider})
	}
	return out, nil
}
