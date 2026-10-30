// SPDX-License-Identifier: FSL-1.1-MIT

package api_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func newService(t *testing.T) (svc *api.Service, alphaToken, betaToken, adminToken string) {
	t.Helper()
	now := time.Unix(1_800_000_000, 0)
	registry := domain.NewRegistry()
	_ = registry.AddTarget(domain.ExecutionTarget{ID: "local", Name: "This machine", Kind: domain.KindLocal})
	_ = registry.AddBinding(domain.SpaceBinding{
		SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared, TrustGroup: "team-a",
	})
	for _, bot := range []string{"alpha", "beta"} {
		_ = registry.Assign(bot, "local:shared", "/bots/"+bot, "team-a")
	}
	state := api.State{Version: 1, Registry: registry, Tokens: domain.NewTokenStore()}
	svc = api.New(state, nil)
	svc.SetClock(func() time.Time { return now })
	space := "local:shared"
	alphaToken, _ = svc.Tokens().Issue("alpha", "team-a", &space, domain.BotCapabilities, now, time.Hour)
	betaToken, _ = svc.Tokens().Issue("beta", "team-a", &space, domain.BotCapabilities, now, time.Hour)
	adminToken, _ = svc.Tokens().Issue("admin", "team-a", nil, []domain.Capability{domain.CapManageRegistry}, now, time.Hour)
	return svc, alphaToken, betaToken, adminToken
}

func call(t *testing.T, svc *api.Service, method, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:5555"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	return rec
}

func TestHealthNeedsNoToken(t *testing.T) {
	svc, _, _, _ := newService(t)
	if rec := call(t, svc, http.MethodGet, "/v1/health", "", ""); rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
}

func TestMissingAndForeignTokensAreRefused(t *testing.T) {
	svc, _, betaToken, _ := newService(t)
	if rec := call(t, svc, http.MethodGet, "/v1/bots/alpha/messages", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 without a token, got %d", rec.Code)
	}
	if rec := call(t, svc, http.MethodGet, "/v1/bots/alpha/messages", betaToken, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("want 403 for another bot's token, got %d", rec.Code)
	}
}

func TestDelegationIsIdempotentOverHTTP(t *testing.T) {
	svc, alphaToken, _, _ := newService(t)
	body := `{"to":"beta","spaceID":"local:shared","prompt":"Summarize","idempotencyKey":"k1","deadlineSeconds":60}`
	first := call(t, svc, http.MethodPost, "/v1/bots/alpha/delegate", alphaToken, body)
	if first.Code != http.StatusCreated {
		t.Fatalf("want 201, got %d: %s", first.Code, first.Body.String())
	}
	second := call(t, svc, http.MethodPost, "/v1/bots/alpha/delegate", alphaToken, body)
	if second.Code != http.StatusOK {
		t.Fatalf("want 200 on the repeated key, got %d", second.Code)
	}
	var a, b map[string]string
	_ = json.Unmarshal(first.Body.Bytes(), &a)
	_ = json.Unmarshal(second.Body.Bytes(), &b)
	if a["id"] != b["id"] {
		t.Fatalf("the retry must return the same task: %v vs %v", a["id"], b["id"])
	}
}

func TestAdminMintsAndBotsCannot(t *testing.T) {
	svc, alphaToken, _, adminToken := newService(t)
	minted := call(t, svc, http.MethodPost, "/v1/manage/bots/beta/token", adminToken, "{}")
	if minted.Code != http.StatusCreated {
		t.Fatalf("want 201, got %d: %s", minted.Code, minted.Body.String())
	}
	var payload map[string]string
	_ = json.Unmarshal(minted.Body.Bytes(), &payload)
	if payload["value"] == "" {
		t.Fatal("the minted credential must be returned once")
	}
	if rec := call(t, svc, http.MethodPost, "/v1/manage/bots/alpha/token", alphaToken, "{}"); rec.Code != http.StatusForbidden {
		t.Fatalf("a bot must not mint tokens, got %d", rec.Code)
	}
	if rec := call(t, svc, http.MethodPost, "/v1/manage/bots/ghost/token", adminToken, "{}"); rec.Code != http.StatusNotFound {
		t.Fatalf("an unknown bot is 404, got %d", rec.Code)
	}
}

func TestBodyLimitAndRateLimit(t *testing.T) {
	svc, alphaToken, _, _ := newService(t)
	svc.BodyLimit = 128
	big := `{"spaceID":"local:shared","body":"` + strings.Repeat("x", 200) + `","idempotencyKey":"big"}`
	if rec := call(t, svc, http.MethodPost, "/v1/bots/alpha/messages", alphaToken, big); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413, got %d", rec.Code)
	}
	svc.BodyLimit = 64 * 1024
	// The budget is the service's own, so read it rather than guessing.
	for i := 0; i < svc.RateLimit; i++ {
		if rec := call(t, svc, http.MethodGet, "/v1/bots/alpha/messages", alphaToken, ""); rec.Code != http.StatusOK {
			t.Fatalf("request %d: want 200, got %d", i, rec.Code)
		}
	}
	if rec := call(t, svc, http.MethodGet, "/v1/bots/alpha/messages", alphaToken, ""); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429 after the budget, got %d", rec.Code)
	}
}

func TestCallersThatAreNotLoopbackAreRefusedUnlessAllowed(t *testing.T) {
	svc, _, _, _ := newService(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/health", nil)
	req.RemoteAddr = "example.invalid:1234"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("want 403 from a non-loopback address, got %d", rec.Code)
	}
	svc.AllowRemote = true
	rec = httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("a VPN listener may answer, got %d", rec.Code)
	}
}
