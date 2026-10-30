// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// ScheduleStore is the scheduler's file as the API needs it: one mutation at a
// time, under the cross-process lock.
type ScheduleStore interface {
	Lock(owner string, body func(*domain.Scheduler) error) error
}

type routineBody struct {
	Title    string  `json:"title"`
	Prompt   string  `json:"prompt"`
	EverySec float64 `json:"everySec"`
	DelaySec float64 `json:"delaySec"`
}

// addRoutine answers POST /v1/bots/<id>/routines. A routine belongs to the Bot
// in the path, which is what makes it the Bot's own schedule rather than a
// global cron: the same list shows up in that Bot's screen and nowhere else.
func (s *Service) addRoutine(botID string, body []byte, now time.Time) (int, any) {
	if s.Schedule == nil {
		return http.StatusServiceUnavailable, map[string]string{"error": "the scheduler is not configured"}
	}
	var in routineBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	in.Title = strings.TrimSpace(in.Title)
	in.Prompt = strings.TrimSpace(in.Prompt)
	if in.Title == "" || in.Prompt == "" {
		return http.StatusBadRequest, map[string]string{"error": "title and prompt are required"}
	}
	if in.EverySec < 60 {
		// Anything faster turns into a queue of turns for one Bot.
		return http.StatusBadRequest, map[string]string{"error": "the interval must be at least 60 seconds"}
	}
	if in.DelaySec < 0 {
		return http.StatusBadRequest, map[string]string{"error": "the delay cannot be negative"}
	}
	var id string
	err := s.Schedule.Lock("service", func(state *domain.Scheduler) error {
		created, err := state.AddJob(botID, in.Title, in.Prompt, in.EverySec,
			now.Add(time.Duration(in.DelaySec)*time.Second))
		id = created
		return err
	})
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	job, ok := s.routineOf(botID, id)
	if !ok {
		return http.StatusCreated, map[string]string{"id": id}
	}
	return http.StatusCreated, toRoutineRow(job)
}

// changeRoutine answers POST /v1/bots/<id>/routines/<job>/{pause,resume}.
func (s *Service) changeRoutine(botID, jobID string, paused bool) (int, any) {
	if s.Schedule == nil {
		return http.StatusServiceUnavailable, map[string]string{"error": "the scheduler is not configured"}
	}
	if _, ok := s.routineOf(botID, jobID); !ok {
		return http.StatusNotFound, map[string]string{"error": "no such routine for this bot"}
	}
	err := s.Schedule.Lock("service", func(state *domain.Scheduler) error {
		state.SetPaused(jobID, paused)
		return nil
	})
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	job, _ := s.routineOf(botID, jobID)
	return http.StatusOK, toRoutineRow(job)
}

// removeRoutine answers DELETE /v1/bots/<id>/routines/<job>. Undelivered slots
// go with it, so a deleted routine cannot still fire once.
func (s *Service) removeRoutine(botID, jobID string) (int, any) {
	if s.Schedule == nil {
		return http.StatusServiceUnavailable, map[string]string{"error": "the scheduler is not configured"}
	}
	if _, ok := s.routineOf(botID, jobID); !ok {
		return http.StatusNotFound, map[string]string{"error": "no such routine for this bot"}
	}
	err := s.Schedule.Lock("service", func(state *domain.Scheduler) error {
		return state.RemoveJob(jobID)
	})
	if err != nil {
		return statusFor(err), map[string]string{"error": err.Error()}
	}
	return http.StatusOK, map[string]string{"removed": jobID}
}

// routineOf reads one job from the scheduler's file, so a Bot can only touch
// its own routines.
func (s *Service) routineOf(botID, jobID string) (domain.Job, bool) {
	for _, job := range s.routineRows() {
		if job.ID == jobID && job.BotID == botID {
			return job, true
		}
	}
	return domain.Job{}, false
}
