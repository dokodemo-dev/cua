// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestRoutinesReadsTheSchedulerFileForOneBot(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	dir := t.TempDir()
	svc.SchedulerDir = dir

	// Nothing saved yet is an empty list, not an error: the scheduler may not
	// have written its file, or may not be running.
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/routines", credential, ""); rec.Code != http.StatusOK {
		t.Fatalf("empty: %d", rec.Code)
	}

	saved := `{"jobs":{
	  "j1":{"id":"j1","botID":"alpha","title":"Daily","prompt":"Summarize","cadence":86400,"nextRunAt":1800000000,"isPaused":true},
	  "j2":{"id":"j2","botID":"beta","title":"Other","prompt":"x","cadence":3600,"nextRunAt":1800000100}
	}}`
	if err := os.WriteFile(filepath.Join(dir, "scheduler.json"), []byte(saved), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/routines", credential, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list: %d", rec.Code)
	}
	var got struct {
		Routines []RoutineRow `json:"routines"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Routines) != 1 || got.Routines[0].Title != "Daily" || !got.Routines[0].Paused {
		t.Fatalf("another bot's routine leaked in, or the fields are wrong: %+v", got.Routines)
	}
}

func TestRoutinesNeedsTheBotsOwnCredential(t *testing.T) {
	svc, credential, _ := chatFixture(t)
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/routines", credential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("another bot's credential: %d", rec.Code)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/routines", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}
