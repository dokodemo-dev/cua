// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"testing"
)

// Archiving has to reach the scheduler: a routine runs cua-bot-turn directly,
// so the Bot's token check alone does not stop it.
func TestArchivingPausesTheBotsRoutinesAndRestoringResumesThem(t *testing.T) {
	svc, credential, admin := routineFixture(t)

	routine := decodeRoutine(t, chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines",
		credential, `{"title":"nightly","prompt":"p","everySec":3600}`).Body.Bytes())
	other := decodeRoutine(t, chatCall(t, svc, http.MethodPost, "/v1/bots/beta/routines",
		admin, `{"title":"beta's","prompt":"p","everySec":3600}`).Body.Bytes())

	rec := chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/archive", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("archive: %d %s", rec.Code, rec.Body)
	}
	if !contains(rec.Body.String(), `"routinesChanged":1`) {
		t.Fatalf("the archive did not report the routines it paused: %s", rec.Body)
	}

	// The API refuses an archived Bot, so read the schedule itself.
	if paused := pausedOf(t, svc, "alpha"); paused != true {
		t.Fatal("alpha's routine still runs")
	}
	if paused := pausedOf(t, svc, "beta"); paused {
		t.Fatal("another Bot's routine was paused")
	}
	if other.ID == "" {
		t.Fatal("the fixture did not create beta's routine")
	}

	rec = chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/unarchive", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("unarchive: %d %s", rec.Code, rec.Body)
	}
	if paused := pausedOf(t, svc, "alpha"); paused {
		t.Fatal("the routine was not resumed")
	}
	if routine.ID == "" {
		t.Fatal("the fixture did not create alpha's routine")
	}
}

// pausedOf reports the pause state of a Bot's first routine.
func pausedOf(t *testing.T, svc *Service, botID string) bool {
	t.Helper()
	for _, job := range svc.routineRows() {
		if job.BotID == botID {
			return job.Paused
		}
	}
	t.Fatalf("no routine for %s", botID)
	return false
}

// A routine the operator stopped by hand must stay stopped after a round trip
// through the archive.
func TestRestoringDoesNotResumeAHandPausedRoutine(t *testing.T) {
	svc, credential, admin := routineFixture(t)
	routine := decodeRoutine(t, chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines",
		credential, `{"title":"mine","prompt":"p","everySec":3600}`).Body.Bytes())
	if rec := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/routines/"+routine.ID+"/pause",
		credential, ""); rec.Code != http.StatusOK {
		t.Fatalf("pause: %d %s", rec.Code, rec.Body)
	}

	chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/archive", admin, "")
	chatCall(t, svc, http.MethodPost, "/v1/manage/bots/alpha/unarchive", admin, "")

	if paused := pausedOf(t, svc, "alpha"); !paused {
		t.Fatal("the operator's pause was undone")
	}
}
