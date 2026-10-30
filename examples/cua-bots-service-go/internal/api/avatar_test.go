// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"testing"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func TestABotAvatarIsStoredAndListed(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/avatar", credential,
		`{"color":"orange","eyes":"happy","ears":"round"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("set avatar: %d %s", rec.Code, rec.Body)
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots", credential, "")
	if !contains(list.Body.String(), `"alpha":{"color":"orange","eyes":"happy","ears":"round"}`) {
		t.Fatalf("the list should carry the face: %s", list.Body)
	}
}

func TestAnewBotGetsAFaceFromItsName(t *testing.T) {
	want := domain.DefaultAvatar("gamma")
	if want.Color == "" {
		t.Fatal("a default face must have a colour")
	}
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots", admin,
		`{"botID":"gamma","spaceID":"local:own"}`); rec.Code != http.StatusCreated {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if !contains(list.Body.String(), `"gamma":{"color":"`+want.Color+`"`) {
		t.Fatalf("no face for the new bot: %s", list.Body)
	}
}

func TestAvatarValuesAreChecked(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	for _, body := range []string{
		`{"color":"puce"}`,
		`{"eyes":"wink"}`,
		`{"ears":"big"}`,
		`not json`,
	} {
		if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/avatar", credential, body); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d", body, rec.Code)
		}
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/beta/avatar", credential, `{"color":"sky"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's face: %d", rec.Code)
	}
}
