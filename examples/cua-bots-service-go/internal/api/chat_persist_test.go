// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func TestChatTurnsSurviveARestartAndRunningOnesBecomeFailed(t *testing.T) {
	svc, credential, now := chatFixture(t)
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		write("hello")
		return nil
	})
	start := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", credential, `{"prompt":"hi"}`)
	if start.Code != http.StatusAccepted {
		t.Fatalf("start: %d", start.Code)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		list := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/chat?after=0", credential, "")
		if strings.Contains(list.Body.String(), `"status":"done"`) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("turn did not finish: %s", list.Body)
		}
		time.Sleep(10 * time.Millisecond)
	}

	// A restart: the saved state is what the next process reads.
	saved := svc.Snapshot()
	again := New(saved, nil)
	again.SetClock(func() time.Time { return now })
	again.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error { return nil })
	list := chatCall(t, again, http.MethodGet, "/v1/bots/alpha/chat?after=0", credential, "")
	if !strings.Contains(list.Body.String(), "hello") {
		t.Fatalf("the turn was not restored: %s", list.Body)
	}

	// A turn that was running when the process died must not look alive.
	saved.Turns = map[string][]Turn{"alpha": {{ID: "turn-x", Prompt: "p", Status: "running"}}}
	restarted := New(saved, nil)
	restarted.SetClock(func() time.Time { return now })
	list = chatCall(t, restarted, http.MethodGet, "/v1/bots/alpha/chat?after=0", credential, "")
	if !strings.Contains(list.Body.String(), `"status":"failed"`) {
		t.Fatalf("a running turn must be marked failed after a restart: %s", list.Body)
	}
}

func TestBotListNarrowsToOneBotWithoutTheRegistryCapability(t *testing.T) {
	svc, credential, now := chatFixture(t)
	admin, err := svc.Tokens().Issue("admin", "default", nil,
		[]domain.Capability{domain.CapManageRegistry}, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	all := chatCall(t, svc, http.MethodGet, "/v1/bots", admin, "")
	if all.Code != http.StatusOK || !strings.Contains(all.Body.String(), "beta") {
		t.Fatalf("administrator list: %d %s", all.Code, all.Body)
	}
	own := chatCall(t, svc, http.MethodGet, "/v1/bots", credential, "")
	if own.Code != http.StatusOK || strings.Contains(own.Body.String(), "beta") {
		t.Fatalf("a bot must not see the others: %d %s", own.Code, own.Body)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}
