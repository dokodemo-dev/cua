// SPDX-License-Identifier: FSL-1.1-MIT

package store_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/store"
)

func TestStateSurvivesARestartWithTokensAndTasks(t *testing.T) {
	dir := t.TempDir()
	file, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	registry := domain.NewRegistry()
	_ = registry.AddTarget(domain.ExecutionTarget{ID: "local", Name: "This machine", Kind: domain.KindLocal})
	_ = registry.AddBinding(domain.SpaceBinding{
		SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared, TrustGroup: "team-a",
	})
	_ = registry.Assign("alpha", "local:shared", "/bots/alpha", "team-a")
	_ = registry.Assign("beta", "local:shared", "/bots/beta", "team-a")

	service := api.New(api.State{Version: 1, Registry: registry, Tokens: domain.NewTokenStore()}, file)
	service.SetClock(func() time.Time { return now })
	space := "local:shared"
	token, err := service.Tokens().Issue("alpha", "team-a", &space, domain.BotCapabilities, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Save(); err != nil {
		t.Fatal(err)
	}

	// A restart: read only what is on disk.
	reopened, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reopened.Close() }()
	state, err := reopened.Load()
	if err != nil {
		t.Fatal(err)
	}
	restarted := api.New(state, reopened)
	if principal := restarted.Tokens().Authenticate(token, now); principal == nil || principal.BotID != "alpha" {
		t.Fatal("the credential must still authenticate after a restart")
	}

	info, err := os.Stat(filepath.Join(dir, "service-state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("the state file must be 0600, got %o", mode)
	}
	if principal := restarted.Tokens().Authenticate(token, now.Add(2*time.Hour)); principal != nil {
		t.Fatal("an expired credential must not authenticate")
	}
}

func TestTheSwiftStateShapeIsReadable(t *testing.T) {
	// The Swift build writes the same keys; a file from it must load here.
	swift := `{
	  "version": 1,
	  "registry": {"targets": {"local": {"id": "local", "name": "This Mac", "kind": "local"}},
	    "bindings": {"local:shared": {"spaceID": "local:shared", "targetID": "local",
	      "mode": "shared", "managedByApp": false, "trustGroup": "team-a",
	      "workspaces": {"alpha": "/bots/alpha"}}}},
	  "tokens": {"entries": {}},
	  "collaboration": {"stored": {}, "byKey": {}, "messages": [], "artifacts": []}
	}`
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "service-state.json"), []byte(swift), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	state, err := file.Load()
	if err != nil {
		t.Fatal(err)
	}
	binding, ok := state.Registry.Bindings["local:shared"]
	if !ok {
		t.Fatal("the binding must load")
	}
	if got := binding.BotIDs(); len(got) != 1 || got[0] != "alpha" {
		t.Fatalf("the assigned bot must load, got %v", got)
	}
	// Saving it back keeps the shape the other side reads.
	if err := file.Save(state); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "service-state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var round map[string]any
	if err := json.Unmarshal(raw, &round); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"version", "registry", "tokens", "collaboration"} {
		if _, ok := round[key]; !ok {
			t.Fatalf("missing %q after a round trip", key)
		}
	}
}
