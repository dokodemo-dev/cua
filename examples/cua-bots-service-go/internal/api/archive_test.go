// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"testing"
	"time"
)

func TestArchivingHidesAReleaseAndKeepsEverythingElse(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/beta/archive", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("archive: %d %s", rec.Code, rec.Body)
	}

	// The picker no longer offers it, unless an administrator asks for it.
	list := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if contains(list.Body.String(), `"bots":["alpha","beta"]`) || !contains(list.Body.String(), `"bots":["alpha"]`) {
		t.Fatalf("live list: %s", list.Body)
	}
	withArchived := chatCall(t, svc, http.MethodGet, "/v1/bots?archived=1", admin, "")
	if !contains(withArchived.Body.String(), `"archived":["beta"]`) {
		t.Fatalf("archived list: %s", withArchived.Body)
	}

	// It keeps its Space and workspace, so putting it back needs no decisions.
	if _, ok := svc.Registry().Bindings["local:shared"].Workspaces["beta"]; !ok {
		t.Fatal("archiving must not unbind the Bot")
	}

	// Its credential stops working: an archived Bot must not run.
	if p := svc.Tokens().Authenticate(botCredential, now); p != nil {
		_ = p
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/chat?after=0", admin, ""); rec.Code != http.StatusConflict {
		t.Fatalf("archived bot ran: %d %s", rec.Code, rec.Body)
	}
}

func TestArchivingRevokesTheBotsCredentials(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	if svc.Tokens().Authenticate(botCredential, now) == nil {
		t.Fatal("the fixture credential should work first")
	}
	chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/archive", admin, "")
	if p := svc.Tokens().Authenticate(botCredential, now); p != nil {
		t.Fatalf("an archived Bot's credential still authenticates: %+v", p)
	}
}

func TestUnarchivingBringsTheBotBackWithItsHistory(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		write("remembered")
		return nil
	})
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/beta/chat", admin, `{"prompt":"hi"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("turn before archiving: %d %s", rec.Code, rec.Body)
	}

	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/beta/archive", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("archive: %d %s", rec.Code, rec.Body)
	}
	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/beta/unarchive", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("unarchive: %d %s", rec.Code, rec.Body)
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if !contains(list.Body.String(), "beta") || !contains(list.Body.String(), `"archived":[]`) {
		t.Fatalf("live list: %s", list.Body)
	}
	// The history survived, which is the point of archiving rather than deleting.
	// The turn finishes in the background, so give it a moment to land.
	deadline := time.Now().Add(2 * time.Second)
	for {
		history := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/chat?after=0", admin, "")
		if history.Code != http.StatusOK {
			t.Fatalf("history after restore: %d %s", history.Code, history.Body)
		}
		if contains(history.Body.String(), "remembered") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("history after restore: %s", history.Body)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestArchivingNeedsAnAdministratorAndAnExistingBot(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/archive", botCredential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot archived itself: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/nobody/archive", admin, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown bot: %d", rec.Code)
	}
	// A stale credential must not resurrect anything either.
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/archive", "", ""); rec.Code != http.StatusForbidden {
		t.Fatalf("no credential: %d", rec.Code)
	}
}
