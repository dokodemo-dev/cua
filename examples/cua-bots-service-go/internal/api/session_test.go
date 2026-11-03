// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A credential link was retired with the one-time-code sign-in: the service
// refuses it and sets no cookie.
// sessionCookie trades a credential for the browser's session cookie, the way
// the sign-in field does.
func sessionCookie(t *testing.T, svc *Service, token string) *http.Cookie {
	t.Helper()
	rec := chatCall(t, svc, http.MethodPost, "/v1/login/exchange", "",
		`{"token":"`+token+`"}`)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("exchange: %d %s", rec.Code, rec.Body)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("no session cookie")
	}
	return cookies[0]
}

func TestACredentialLinkIsGone(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	req := httptest.NewRequest(http.MethodGet, "/ui?login="+admin, nil)
	req.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusGone {
		t.Fatalf("login link: %d", rec.Code)
	}
	if len(rec.Result().Cookies()) != 0 {
		t.Fatalf("a retired link set a cookie: %v", rec.Result().Cookies())
	}
	if strings.Contains(rec.Body.String(), admin) {
		t.Fatal("the answer contains the credential")
	}
}

func TestLogoutClearsTheSessionCookie(t *testing.T) {
	svc, _, _ := chatFixture(t)
	req := httptest.NewRequest(http.MethodGet, "/ui?logout=1", nil)
	req.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	cookies := rec.Result().Cookies()
	if rec.Code != http.StatusSeeOther || len(cookies) == 0 || cookies[0].MaxAge >= 0 {
		t.Fatalf("logout did not expire the cookie: %d %v", rec.Code, cookies)
	}
}

func TestCreatingABotStartsItsSpaceInTheBackground(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	started := make(chan string, 1)
	release := make(chan struct{})
	svc.Provisioner = func(ctx context.Context, botID, spaceID string) error {
		started <- spaceID
		<-release
		return errors.New("image pull failed")
	}

	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"gamma","spaceID":"local:bot-gamma","createSpace":true}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	select {
	case spaceID := <-started:
		if spaceID != "local:bot-gamma" {
			t.Fatalf("provisioned the wrong space: %s", spaceID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the Space build never started")
	}

	// While it runs, the browser is told to wait.
	state := spaceState(t, svc, "gamma")
	if state.State != "pending" {
		t.Fatalf("state while building: %+v", state)
	}
	close(release)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if state := spaceState(t, svc, "gamma"); state.State == "failed" {
			if state.Detail == "" {
				t.Fatal("a failure must say why")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the failure was never recorded")
}

func TestABotWithNoRecordedStateReadsAsReady(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	state := spaceState(t, svc, "alpha")
	if state.State != "ready" || state.SpaceID == "" {
		t.Fatalf("hand-registered bot: %+v", state)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/space", credential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's space: %d", rec.Code)
	}
}

func spaceState(t *testing.T, svc *Service, botID string) SpaceState {
	t.Helper()
	now := time.Unix(1_800_000_000, 0)
	admin := adminCredential(t, svc, now)
	rec := chatCall(t, svc, http.MethodGet, "/v1/bots/"+botID+"/space", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("space: %d %s", rec.Code, rec.Body)
	}
	var state SpaceState
	if err := json.Unmarshal(rec.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	return state
}
