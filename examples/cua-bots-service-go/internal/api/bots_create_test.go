// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func adminCredential(t *testing.T, svc *Service, now time.Time) string {
	t.Helper()
	value, err := svc.Tokens().Issue("admin", "default", nil,
		[]domain.Capability{domain.CapManageRegistry}, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestCreateBotRegistersTheBotAndReturnsItsCredential(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	svc.SecretDir = t.TempDir()

	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"gamma","spaceID":"local:new-space","trustGroup":"team-a","createSpace":true}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["botID"] != "gamma" || got["credential"] == "" {
		t.Fatalf("response: %v", got)
	}

	// The new credential authenticates as that Bot, and the Bot is bound.
	if p := svc.Tokens().Authenticate(got["credential"], now); p == nil || p.BotID != "gamma" {
		t.Fatalf("the issued credential does not authenticate: %+v", p)
	}
	if _, ok := svc.Registry().Bindings["local:new-space"].Workspaces["gamma"]; !ok {
		t.Fatal("the Bot was not bound to the Space")
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if !contains(list.Body.String(), "gamma") {
		t.Fatalf("the new Bot is not listed: %s", list.Body)
	}
}

func TestCreateBotRefusesBadInputAndNonAdmins(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", botCredential,
		`{"botID":"gamma","spaceID":"local:x"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot must not create Bots: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", "",
		`{"botID":"gamma","spaceID":"local:x"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("no credential: %d", rec.Code)
	}
	for _, body := range []string{
		`{"botID":"","spaceID":"local:x"}`,
		`{"botID":"gamma","spaceID":""}`,
		`{"botID":"bad name","spaceID":"local:x"}`,
		`not json`,
	} {
		if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin, body); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d", body, rec.Code)
		}
	}
}

// A browser picks a Space, not a trust group. Creating a Bot in an existing
// Space must therefore inherit that Space's group instead of being refused.
func TestCreateBotInheritsTheSpacesTrustGroup(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	if err := svc.Registry().AddBinding(domain.SpaceBinding{
		TargetID:   "t1",
		Mode:       domain.ModeShared,
		SpaceID:    "local:team-a",
		TrustGroup: "team-a",
		Workspaces: map[string]string{},
	}); err != nil {
		t.Fatal(err)
	}

	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"gamma","spaceID":"local:team-a"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	binding := svc.Registry().Bindings["local:team-a"]
	if _, ok := binding.Workspaces["gamma"]; !ok {
		t.Fatal("the Bot was not bound to the Space")
	}
}

// The 400 for a rejected name must say what a name may contain; the browser
// shows this text as-is.
func TestCreateBotExplainsTheNameRule(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"Delta","spaceID":"local:shared"}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d", rec.Code)
	}
	if !contains(rec.Body.String(), "a-z") {
		t.Fatalf("the message does not explain the rule: %s", rec.Body)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (haystack == needle || indexOf(haystack, needle) >= 0)
}

func indexOf(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
