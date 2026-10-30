// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// fileSchedule is the scheduler's file as the tests need it, without pulling in
// the store package (which imports this one).
type fileSchedule struct {
	path string
	mu   sync.Mutex
}

func (f *fileSchedule) Lock(owner string, body func(*domain.Scheduler) error) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	state := domain.NewScheduler(owner)
	if data, err := os.ReadFile(f.path); err == nil {
		if err := json.Unmarshal(data, state); err != nil {
			return err
		}
	}
	if err := body(state); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(f.path, data, 0o600)
}

func routineFixture(t *testing.T) (*Service, string, string) {
	t.Helper()
	svc, credential, now := chatFixture(t)
	dir := t.TempDir()
	svc.SchedulerDir = dir
	svc.Schedule = &fileSchedule{path: filepath.Join(dir, "scheduler.json")}
	admin := adminCredential(t, svc, now)
	return svc, credential, admin
}

func decodeRoutine(t *testing.T, body []byte) RoutineRow {
	t.Helper()
	var row RoutineRow
	if err := json.Unmarshal(body, &row); err != nil {
		t.Fatal(err)
	}
	return row
}

func TestABotKeepsItsOwnRoutines(t *testing.T) {
	svc, botCredential, _ := routineFixture(t)

	rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines", botCredential,
		`{"title":"朝のまとめ","prompt":"昨夜の変更を要約して","everySec":86400,"delaySec":600}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("add: %d %s", rec.Code, rec.Body)
	}
	created := decodeRoutine(t, rec.Body.Bytes())
	if created.Title != "朝のまとめ" || created.Paused {
		t.Fatalf("row: %+v", created)
	}

	// The routine is the Bot's: alpha sees it, beta does not.
	mine := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/routines", botCredential, "")
	if !contains(mine.Body.String(), "朝のまとめ") {
		t.Fatalf("alpha's list: %s", mine.Body)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/beta/routines", botCredential, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("beta with alpha's credential: %d", rec.Code)
	}
}

func TestRoutinesCanBePausedResumedAndRemoved(t *testing.T) {
	svc, botCredential, _ := routineFixture(t)
	created := decodeRoutine(t, chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines", botCredential,
		`{"title":"t","prompt":"p","everySec":3600}`).Body.Bytes())

	paused := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines/"+created.ID+"/pause", botCredential, "")
	if paused.Code != http.StatusOK || !decodeRoutine(t, paused.Body.Bytes()).Paused {
		t.Fatalf("pause: %d %s", paused.Code, paused.Body)
	}
	resumed := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines/"+created.ID+"/resume", botCredential, "")
	if resumed.Code != http.StatusOK || decodeRoutine(t, resumed.Body.Bytes()).Paused {
		t.Fatalf("resume: %d %s", resumed.Code, resumed.Body)
	}
	if rec := chatCall(t, svc, http.MethodDelete, "/v1/bots/alpha/routines/"+created.ID, botCredential, ""); rec.Code != http.StatusOK {
		t.Fatalf("remove: %d %s", rec.Code, rec.Body)
	}
	list := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/routines", botCredential, "")
	if contains(list.Body.String(), created.ID) {
		t.Fatalf("the routine survived removal: %s", list.Body)
	}
}

func TestAnotherBotsRoutineCannotBeTouched(t *testing.T) {
	svc, _, admin := routineFixture(t)
	// beta's routine, created by the administrator.
	other := decodeRoutine(t, chatCall(t, svc, http.MethodPost, "/v1/bots/beta/routines", admin,
		`{"title":"beta's","prompt":"p","everySec":3600}`).Body.Bytes())

	alpha := adminCredentialFor(t, svc, "alpha")
	for _, call := range []struct {
		method, path string
	}{
		{http.MethodPost, "/v1/bots/alpha/routines/" + other.ID + "/pause"},
		{http.MethodDelete, "/v1/bots/alpha/routines/" + other.ID},
	} {
		if rec := chatCall(t, svc, call.method, call.path, alpha, ""); rec.Code != http.StatusNotFound {
			t.Fatalf("%s %s: %d", call.method, call.path, rec.Code)
		}
	}
}

func TestRoutineInputIsChecked(t *testing.T) {
	svc, botCredential, _ := routineFixture(t)
	for _, body := range []string{
		`{"title":"","prompt":"p","everySec":3600}`,
		`{"title":"t","prompt":"","everySec":3600}`,
		`{"title":"t","prompt":"p","everySec":30}`,
		`{"title":"t","prompt":"p","everySec":3600,"delaySec":-5}`,
		`not json`,
	} {
		if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines", botCredential, body); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d", body, rec.Code)
		}
	}
}

// adminCredentialFor issues a credential for one Bot, to prove a Bot credential
// cannot reach another Bot's routines.
func adminCredentialFor(t *testing.T, svc *Service, botID string) string {
	t.Helper()
	space := "local:shared"
	value, err := svc.Tokens().Issue(botID, "default", &space, domain.BotCapabilities, svc.now(), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return value
}
