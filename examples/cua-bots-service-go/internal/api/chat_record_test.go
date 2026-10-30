// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"strings"
	"testing"
)

func TestARoutineTurnCanBeRecordedWithoutRunningOne(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	ran := false
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		ran = true
		return nil
	})

	rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat/record", credential,
		`{"prompt":"routine prompt","output":"routine reply","status":"done"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("record: %d %s", rec.Code, rec.Body)
	}
	if ran {
		t.Fatal("recording must not start a turn")
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/chat?after=0", credential, "")
	if !strings.Contains(list.Body.String(), "routine reply") {
		t.Fatalf("the recorded turn is not in the window: %s", list.Body)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/beta/chat/record", credential,
		`{"prompt":"x","output":"y"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's credential: %d", rec.Code)
	}
}
