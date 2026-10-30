// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestBotListCarriesWhenEachBotLastRan(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	// A finished turn for alpha; beta has none.
	svc.chat.Record("alpha", "hi", "ok", StatusDone)
	rec := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	var payload struct {
		Activity map[string]float64 `json:"activity"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Activity["alpha"] <= 0 {
		t.Fatalf("alpha has no activity: %+v", payload.Activity)
	}
	if _, ok := payload.Activity["beta"]; ok {
		t.Fatalf("beta never ran but has activity: %+v", payload.Activity)
	}
}
