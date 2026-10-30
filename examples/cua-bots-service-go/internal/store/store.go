// SPDX-License-Identifier: FSL-1.1-MIT

// Package store persists the service state: one JSON file, written atomically
// while holding an exclusive lock, so a crash leaves either the old or the new
// state. The file is 0600 because it holds messages and artifact names.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
)

// File is the state file inside a directory.
type File struct {
	dir  string
	lock *os.File
}

// Open prepares the directory and the lock file.
func Open(dir string) (*File, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "service-state.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	return &File{dir: dir, lock: lock}, nil
}

// Close releases the lock file.
func (f *File) Close() error { return f.lock.Close() }

// Path is where the state lives.
func (f *File) Path() string { return filepath.Join(f.dir, "service-state.json") }

// Load reads the state; a missing file is empty state, not an error.
func (f *File) Load() (api.State, error) {
	data, err := os.ReadFile(f.Path())
	if errors.Is(err, os.ErrNotExist) {
		return api.State{Version: 1}, nil
	}
	if err != nil {
		return api.State{}, err
	}
	var state api.State
	if err := json.Unmarshal(data, &state); err != nil {
		return api.State{}, fmt.Errorf("state file is not valid JSON: %w", err)
	}
	if state.Version != 0 && state.Version != 1 {
		return api.State{}, fmt.Errorf("unsupported state version %d", state.Version)
	}
	return state, nil
}

// Save writes the state atomically while holding the lock.
func (f *File) Save(state api.State) error {
	if err := syscall.Flock(int(f.lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer func() { _ = syscall.Flock(int(f.lock.Fd()), syscall.LOCK_UN) }()
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	tmp := f.Path() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, f.Path()); err != nil {
		return err
	}
	return os.Chmod(f.Path(), 0o600)
}
