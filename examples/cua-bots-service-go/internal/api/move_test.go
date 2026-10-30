// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"testing"
)

func TestMovingABotPointsItAtTheSpaceItReallyRunsIn(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/space", admin,
		`{"spaceID":"local:bot-alpha","createSpace":false}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("move: %d %s", rec.Code, rec.Body)
	}
	bindings := svc.Registry().Bindings
	if _, still := bindings["local:shared"].Workspaces["alpha"]; still {
		t.Fatal("the old binding kept the Bot")
	}
	if _, ok := bindings["local:bot-alpha"].Workspaces["alpha"]; !ok {
		t.Fatal("the Bot did not land in the target Space")
	}
	// The turn runner reads the Space from here, so it must agree.
	if space := svc.SpaceOf("alpha"); space != "local:bot-alpha" {
		t.Fatalf("SpaceOf: %s", space)
	}
}

func TestMovingNeedsAnAdministratorAndASpace(t *testing.T) {
	svc, credential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/space", credential,
		`{"spaceID":"local:x"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot moved itself: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/space", admin,
		``); rec.Code != http.StatusBadRequest {
		t.Fatalf("no space: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/nobody/space", admin,
		`{"spaceID":"local:x"}`); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown bot: %d", rec.Code)
	}
}
