// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// An administrator belongs to no Space, so driving another Bot's chat has to go
// through the path's Bot, not the administrator's own id.
func TestAnAdministratorCanDriveAnyBotFromTheBrowser(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		write("hello from " + botID)
		return nil
	})

	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/beta/chat", admin,
		`{"prompt":"hi"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("start: %d %s", rec.Code, rec.Body)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/chat?after=0", admin, "")
		var got struct {
			Turns []Turn `json:"turns"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if len(got.Turns) == 1 && got.Turns[0].Output == "hello from beta" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the turn was not recorded against the bot named in the path")
}

// A Bot credential must still be confined to its own Bot.
func TestABotCredentialStaysConfinedToItsOwnBot(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/chat?after=0", credential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's chat: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/routines", credential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's routines: %d", rec.Code)
	}
}
