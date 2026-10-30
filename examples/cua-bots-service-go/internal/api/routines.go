// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// RoutineRow is one scheduled job as the browser shows it.
type RoutineRow struct {
	ID        string  `json:"id"`
	Title     string  `json:"title"`
	Prompt    string  `json:"prompt"`
	EverySec  float64 `json:"everySec"`
	NextRunAt float64 `json:"nextRunAt"`
	Paused    bool    `json:"paused"`
}

func toRoutineRow(job domain.Job) RoutineRow {
	return RoutineRow{
		ID: job.ID, Title: job.Title, Prompt: job.Prompt,
		EverySec: job.Cadence, NextRunAt: job.NextRunAt, Paused: job.Paused,
	}
}

// routineRows reads the scheduler's file without taking its lock. A concurrent
// write is caught by the atomic replace, and a half-written or missing file
// simply reads as empty.
func (s *Service) routineRows() []domain.Job {
	if s.SchedulerDir == "" {
		return nil
	}
	data, err := os.ReadFile(filepath.Join(s.SchedulerDir, "scheduler.json"))
	if err != nil {
		return nil
	}
	var state domain.Scheduler
	if err := json.Unmarshal(data, &state); err != nil {
		return nil
	}
	rows := make([]domain.Job, 0, len(state.Jobs))
	for _, job := range state.Jobs {
		rows = append(rows, job)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].NextRunAt < rows[j].NextRunAt })
	return rows
}

// routines answers GET /v1/bots/<id>/routines.
func (s *Service) routines(botID string) (int, any) {
	rows := make([]RoutineRow, 0)
	for _, job := range s.routineRows() {
		if job.BotID == botID {
			rows = append(rows, toRoutineRow(job))
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].NextRunAt < rows[j].NextRunAt })
	return http.StatusOK, map[string]any{
		"routines": rows, "asOf": float64(time.Now().Unix()),
	}
}
