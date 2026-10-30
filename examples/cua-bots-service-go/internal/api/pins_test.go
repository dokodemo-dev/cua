// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

func pinsOf(t *testing.T, svc *Service, credential string) []string {
	t.Helper()
	rec := chatCall(t, svc, http.MethodGet, "/v1/pins", credential, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	var body struct {
		Bots []string `json:"bots"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body.Bots
}

func TestPinsAreOrderedAndSurviveARestart(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/alpha", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("pin alpha: %d %s", rec.Code, rec.Body)
	}
	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/beta", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("pin beta: %d %s", rec.Code, rec.Body)
	}
	// Re-pinning an already pinned Bot must not move or duplicate it.
	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/alpha", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("pin alpha again: %d %s", rec.Code, rec.Body)
	}
	pins := pinsOf(t, svc, admin)
	if len(pins) != 2 || pins[0] != "beta" || pins[1] != "alpha" {
		t.Fatalf("pins: %v", pins)
	}

	restored := New(svc.Snapshot(), nil)
	if got := pinsOf(t, restored, admin); len(got) != 2 || got[0] != "beta" {
		t.Fatalf("pins after restart: %v", got)
	}
}

func TestUnpinRemovesTheBot(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	chatCall(t, svc, http.MethodPut, "/v1/pins/alpha", admin, "")

	if rec := chatCall(t, svc, http.MethodDelete, "/v1/pins/alpha", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("unpin: %d %s", rec.Code, rec.Body)
	}
	if pins := pinsOf(t, svc, admin); len(pins) != 0 {
		t.Fatalf("pins: %v", pins)
	}
	// Deleting an absent pin is not an error: two devices may race.
	if rec := chatCall(t, svc, http.MethodDelete, "/v1/pins/alpha", admin, ""); rec.Code != http.StatusOK {
		t.Fatalf("unpin again: %d", rec.Code)
	}
}

func TestPinsRefuseBotsUnknownBotsAndArchivedOnes(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	if rec := chatCall(t, svc, http.MethodGet, "/v1/pins", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/alpha", botCredential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot pinned itself: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/missing", admin, ""); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown bot: %d", rec.Code)
	}
	if err := svc.Registry().Archive("alpha"); err != nil {
		t.Fatal(err)
	}
	if rec := chatCall(t, svc, http.MethodPut, "/v1/pins/alpha", admin, ""); rec.Code != http.StatusConflict {
		t.Fatalf("archived bot: %d", rec.Code)
	}
}
