// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"fmt"
	"sort"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// jobAdmin is one `--jobs` / `--add-job` style command against the schedule.
//
// The GUI edits routines in memory; on a VPS the schedule is a file, so the
// operator needs the same edits from the shell: add, list, pause, resume and
// remove, each under the scheduler's lock so a running daemon reloads them.
type jobAdmin struct {
	list   bool
	add    string
	remove string
	pause  string
	resume string
	title  string
	prompt string
	every  time.Duration
	delay  time.Duration
	now    time.Time
}

// wants reports whether any job command was requested.
func (a jobAdmin) wants() bool {
	return a.list || a.add != "" || a.remove != "" || a.pause != "" || a.resume != ""
}

// apply runs the command on the locked schedule and returns what to print.
func (a jobAdmin) apply(s *domain.Scheduler) ([]string, error) {
	now := a.now
	if now.IsZero() {
		now = time.Now()
	}
	switch {
	case a.list:
		ids := make([]string, 0, len(s.Jobs))
		for id := range s.Jobs {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return s.Jobs[ids[i]].NextRunAt < s.Jobs[ids[j]].NextRunAt })
		out := make([]string, 0, len(ids))
		for _, id := range ids {
			job := s.Jobs[id]
			state := "active"
			if job.Paused {
				state = "paused"
			}
			out = append(out, fmt.Sprintf("%s bot=%s every=%s next=%s state=%s title=%q",
				job.ID, job.BotID, time.Duration(job.Cadence*float64(time.Second)),
				time.Unix(int64(job.NextRunAt), 0).UTC().Format(time.RFC3339), state, job.Title))
		}
		if len(out) == 0 {
			out = append(out, "no jobs")
		}
		return out, nil
	case a.add != "":
		if a.prompt == "" {
			return nil, fmt.Errorf("--add-job needs --job-prompt")
		}
		if a.every < time.Minute {
			return nil, fmt.Errorf("--job-every must be at least 1m")
		}
		title := a.title
		if title == "" {
			title = a.add
		}
		id, err := s.AddJob(a.add, title, a.prompt, a.every.Seconds(), now.Add(a.delay))
		if err != nil {
			return nil, err
		}
		return []string{fmt.Sprintf("ADDED %s bot=%s every=%s", id, a.add, a.every)}, nil
	case a.remove != "":
		if err := s.RemoveJob(a.remove); err != nil {
			return nil, err
		}
		return []string{fmt.Sprintf("REMOVED %s", a.remove)}, nil
	case a.pause != "":
		if _, ok := s.Jobs[a.pause]; !ok {
			return nil, domain.ErrUnknownJob
		}
		s.SetPaused(a.pause, true)
		return []string{fmt.Sprintf("PAUSED %s", a.pause)}, nil
	case a.resume != "":
		if _, ok := s.Jobs[a.resume]; !ok {
			return nil, domain.ErrUnknownJob
		}
		s.SetPaused(a.resume, false)
		return []string{fmt.Sprintf("RESUMED %s", a.resume)}, nil
	}
	return nil, fmt.Errorf("no job command")
}
