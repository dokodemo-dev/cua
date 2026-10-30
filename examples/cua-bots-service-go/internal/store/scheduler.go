// SPDX-License-Identifier: FSL-1.1-MIT

// Package store persists the scheduler state: one JSON file, atomic replace
// under an exclusive lock, so a crash leaves either the old or the new state.
package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

// Schedule is the scheduler's state file.
type Schedule struct {
	dir  string
	lock *os.File
}

// Open prepares the directory and lock file.
func OpenSchedule(dir string) (*Schedule, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "scheduler.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	return &Schedule{dir: dir, lock: lock}, nil
}

// Close releases the lock file.
func (s *Schedule) Close() error { return s.lock.Close() }

// Path is where the state lives.
func (s *Schedule) Path() string { return filepath.Join(s.dir, "scheduler.json") }

// Lock takes the cross-process lock, runs body on the state, and writes it back.
func (s *Schedule) Lock(owner string, body func(*domain.Scheduler) error) error {
	if err := syscall.Flock(int(s.lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer func() { _ = syscall.Flock(int(s.lock.Fd()), syscall.LOCK_UN) }()

	state := domain.NewScheduler(owner)
	if data, err := os.ReadFile(s.Path()); err == nil {
		var loaded domain.Scheduler
		if err := json.Unmarshal(data, &loaded); err == nil {
			if loaded.Jobs != nil {
				state.Jobs = loaded.Jobs
			}
			if loaded.Deliveries != nil {
				state.Deliveries = loaded.Deliveries
			}
			state.Lease = loaded.Lease
			if loaded.ClaimTimeout > 0 {
				state.ClaimTimeout = loaded.ClaimTimeout
			}
		} else {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	state.OwnerID = owner
	if err := body(state); err != nil {
		return err
	}
	return s.write(state)
}

func (s *Schedule) write(state *domain.Scheduler) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.Path() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.Path()); err != nil {
		return err
	}
	return os.Chmod(s.Path(), 0o600)
}
