// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// The browser polls with a cursor. A turn that is still running has to keep
// coming back even though the cursor moved past it, or its text never grows
// and it never turns into "done".
func TestARunningTurnIsReturnedEvenBehindTheCursor(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	release := make(chan struct{})
	svc.SetTurnRunner(func(turnID, botID, prompt string, write func(string)) error {
		write("first ")
		<-release
		write("second")
		return nil
	})
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat", credential, `{"prompt":"hi"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("start: %d %s", rec.Code, rec.Body)
	}

	read := func(after int) ([]Turn, int) {
		rec := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/chat?after="+itoa(after), credential, "")
		var got struct {
			Turns []Turn `json:"turns"`
			Next  int    `json:"next"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		return got.Turns, got.Next
	}

	deadline := time.Now().Add(2 * time.Second)
	var next int
	for time.Now().Before(deadline) {
		_, n := read(0)
		if n == 1 {
			next = n
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if next != 1 {
		t.Fatalf("the turn never appeared: next=%d", next)
	}

	// Past the cursor, the running turn still has to be reported.
	turns, _ := read(next)
	if len(turns) != 1 || turns[0].Status != StatusRunning {
		t.Fatalf("a running turn behind the cursor was dropped: %+v", turns)
	}

	close(release)
	for time.Now().Before(deadline) {
		turns, _ := read(next)
		if len(turns) == 1 && turns[0].Status == StatusDone {
			if turns[0].Output != "first second" {
				t.Fatalf("output %q", turns[0].Output)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the finished turn was never reported")
}
