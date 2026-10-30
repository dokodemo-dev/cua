// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"testing"
	"time"
)

func timeoutAfter() <-chan time.Time { return time.After(2 * time.Second) }

// Recording a routine turn goes through the same request path as any other
// mutation, and that path already holds the service lock: persisting again from
// inside it deadlocked the service. Guard the call so it can never hang.
func TestRecordingARoutineTurnDoesNotBlockTheService(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	done := make(chan int, 1)
	go func() {
		rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/chat/record", credential,
			`{"prompt":"routine","output":"reply"}`)
		done <- rec.Code
	}()
	select {
	case code := <-done:
		if code != http.StatusCreated {
			t.Fatalf("record: %d", code)
		}
	case <-timeoutAfter():
		t.Fatal("recording a turn blocked the service")
	}
}
