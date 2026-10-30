// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// chatFixture builds a service with alpha and beta bound to one Space, and
// returns alpha's credential.
func chatFixture(t *testing.T) (*Service, string, time.Time) {
	t.Helper()
	registry := domain.NewRegistry()
	if err := registry.AddTarget(domain.ExecutionTarget{ID: "t1", Name: "local", Kind: domain.KindLocal}); err != nil {
		t.Fatal(err)
	}
	if err := registry.AddBinding(domain.SpaceBinding{
		TargetID:   "t1",
		Mode:       domain.ModeShared,
		SpaceID:    "local:shared",
		Workspaces: map[string]string{"alpha": "", "beta": ""},
	}); err != nil {
		t.Fatal(err)
	}
	tokens := domain.NewTokenStore()
	now := time.Unix(1_800_000_000, 0).UTC()
	credential, err := tokens.Issue("alpha", "default", nil, domain.BotCapabilities, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	svc := New(State{Version: 1, Registry: registry, Tokens: tokens}, nil)
	svc.SetClock(func() time.Time { return now })
	return svc, credential, now
}

func chatCall(t *testing.T, svc *Service, method, path, credential, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.RemoteAddr = "127.0.0.1:50000"
	if credential != "" {
		req.Header.Set("Authorization", "Bearer "+credential)
	}
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	return rec
}

func TestChatServesThePageWithoutACredential(t *testing.T) {
	svc, _, _ := chatFixture(t)
	rec := chatCall(t, svc, http.MethodGet, "/ui", "", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "<html") {
		t.Fatal("the page was not served")
	}
}

func TestChatTurnCollectsOutputAndRefusesASecondWhileRunning(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	release := make(chan struct{})
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		write("first ")
		<-release
		write("second")
		return nil
	})

	start := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", credential, `{"prompt":"hi"}`)
	if start.Code != http.StatusAccepted {
		t.Fatalf("start: %d %s", start.Code, start.Body)
	}
	busy := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", credential, `{"prompt":"again"}`)
	if busy.Code != http.StatusTooManyRequests {
		t.Fatalf("a second turn must be refused while one runs: %d", busy.Code)
	}

	close(release)
	deadline := time.Now().Add(2 * time.Second)
	for {
		list := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/chat?after=0", credential, "")
		var got struct {
			Turns []Turn `json:"turns"`
			Next  int    `json:"next"`
		}
		if err := json.Unmarshal(list.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if len(got.Turns) == 1 && got.Turns[0].Status == "done" {
			if got.Turns[0].Output != "first second" {
				t.Fatalf("output %q", got.Turns[0].Output)
			}
			if got.Next != 1 {
				t.Fatalf("next %d", got.Next)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("turn did not finish: %s", list.Body)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestChatNeedsTheBotsOwnCredential(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/beta/chat", credential, `{"prompt":"hi"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's credential: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", "", `{"prompt":"hi"}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", credential, `{"prompt":""}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("empty prompt: %d", rec.Code)
	}
}
