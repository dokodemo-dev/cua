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

func TestLoginLinkSetsASessionCookieTheAPIAccepts(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	req := httptest.NewRequest(http.MethodGet, "/ui?login="+admin, nil)
	req.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	// The login page stores the credential itself, so this is a 200 that both
	// sets the cookie and hands the value to the page.
	if rec.Code != http.StatusOK {
		t.Fatalf("login: %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "localStorage.setItem") {
		t.Fatalf("the page should store the credential: %s", rec.Body)
	}
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 || cookies[0].Name != "cua_session" {
		t.Fatalf("no session cookie: %v", cookies)
	}
	if !cookies[0].HttpOnly {
		t.Fatal("the session cookie must not be readable from script")
	}

	// With the cookie alone, the API must answer as that credential.
	req2 := httptest.NewRequest(http.MethodGet, "/v1/bots", nil)
	req2.RemoteAddr = "127.0.0.1:50000"
	req2.AddCookie(cookies[0])
	rec = httptest.NewRecorder()
	svc.ServeHTTP(rec, req2)
	if rec.Code != http.StatusOK {
		t.Fatalf("cookie auth: %d %s", rec.Code, rec.Body)
	}
}

// A credential that will never work must not look like a successful sign-in.
func TestLoginWithAStaleCredentialSaysSo(t *testing.T) {
	svc, _, _ := chatFixture(t)
	req := httptest.NewRequest(http.MethodGet, "/ui?login=stale-value", nil)
	req.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/ui?login=failed" {
		t.Fatalf("stale credential: %d %q", rec.Code, rec.Header().Get("Location"))
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

// The login page's script must be valid JavaScript, or the browser stays on it
// with nothing stored.
func TestTheLoginPageScriptIsNotBrokenByEscaping(t *testing.T) {
	page := string(loginPage("tok-with-\"quotes\"", "/ui/alpha/library"))
	if strings.Contains(page, "&#34;") {
		t.Fatalf("the literal was HTML-escaped: %s", page)
	}
	if !strings.Contains(page, `"tok-with-\"quotes\""`) {
		t.Fatalf("the credential is not a JS string literal: %s", page)
	}
	// The link keeps pointing at the page it was for.
	if !strings.Contains(page, `location.replace("/ui/alpha/library")`) {
		t.Fatalf("the path was not carried through: %s", page)
	}
}
