// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func TestSpacesListsWhatTheHostHasForAnAdministratorOnly(t *testing.T) {
	svc, credential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	svc.SpaceLister = func(ctx context.Context) ([]SpaceInfo, error) {
		return []SpaceInfo{{ID: "local:bot-alpha", Name: "bot-alpha", Kind: "container"}}, nil
	}

	rec := chatCall(t, svc, http.MethodGet, "/v1/spaces", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("admin: %d %s", rec.Code, rec.Body)
	}
	if !contains(rec.Body.String(), "local:bot-alpha") {
		t.Fatalf("the Space is missing: %s", rec.Body)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/spaces", credential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot must not list Spaces: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/spaces", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}

// Picking an existing Space must not rebuild it.
func TestABotPutInAnExistingSpaceIsNotProvisioned(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	called := false
	svc.Provisioner = func(ctx context.Context, botID, spaceID string) error {
		called = true
		return nil
	}
	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"gamma","spaceID":"local:bot-alpha"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	if called {
		t.Fatal("an existing Space was rebuilt")
	}
	if state := spaceState(t, svc, "gamma"); state.State != "ready" {
		t.Fatalf("state: %+v", state)
	}
}

func TestParseSpacesReadsTheCLIOutput(t *testing.T) {
	body := `{"spaces":[{"id":"local:bot-alpha","display_name":"bot-alpha","kind":"container","provider":"local"}]}`
	list, err := ParseSpaces([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].ID != "local:bot-alpha" || list[0].Name != "bot-alpha" {
		t.Fatalf("%+v", list)
	}
}

func TestSpaceViewsNameTheBotsAndFlagMissingSpaces(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	// beta is bound to local:shared (chatFixture); give gamma a Space the host
	// does not list, the way a deleted Space looks.
	if err := svc.registry.AddBinding(domain.SpaceBinding{
		TargetID:   "t1",
		Mode:       domain.ModeShared,
		SpaceID:    "local:gone",
		Workspaces: map[string]string{"gamma": ""},
	}); err != nil {
		t.Fatal(err)
	}
	svc.SpaceLister = func(ctx context.Context) ([]SpaceInfo, error) {
		return []SpaceInfo{{ID: "local:shared", Name: "shared", Kind: "container"}}, nil
	}
	rec := chatCall(t, svc, http.MethodGet, "/v1/spaces", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	var payload struct {
		Spaces []SpaceView `json:"spaces"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Spaces) != 2 {
		t.Fatalf("spaces: %+v", payload.Spaces)
	}
	byID := map[string]SpaceView{}
	for _, space := range payload.Spaces {
		byID[space.ID] = space
	}
	shared := byID["local:shared"]
	if !shared.Registered || len(shared.Bots) != 2 {
		t.Fatalf("shared: %+v", shared)
	}
	gone := byID["local:gone"]
	if gone.Registered {
		t.Fatalf("a Space missing from the host read as registered: %+v", gone)
	}
	if len(gone.Bots) != 1 || gone.Bots[0] != "gamma" {
		t.Fatalf("gone bots: %+v", gone.Bots)
	}
}
