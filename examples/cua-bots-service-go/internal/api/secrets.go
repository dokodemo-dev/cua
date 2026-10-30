// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Provider keys entered in the Web UI. They live in one file next to the Bot
// tokens (0600, the service user's own), which cua-bot-turn reads when a turn
// names a key the host environment does not have. turn.env stays the fallback
// for anything set there by hand, and an environment value always wins.
//
// The API never returns a key: only its name, last four characters and the time
// it was saved.
type keysFile struct {
	// Keys maps a variable name (OPENAI_API_KEY) to its value.
	Keys map[string]storedKey `json:"keys"`
}

type storedKey struct {
	Value   string `json:"value"`
	Updated int64  `json:"updated,omitempty"`
}

var keyValueProblem = regexp.MustCompile(`[\x00-\x1f\x7f]`)

// KeysPath is where the Web UI's keys are kept. Empty disables the feature.
func (s *Service) keysPath() string {
	if s.KeysPath == "" {
		return ""
	}
	return s.KeysPath
}

func (s *Service) loadKeys() (keysFile, error) {
	path := s.keysPath()
	if path == "" {
		return keysFile{}, nil
	}
	body, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return keysFile{Keys: map[string]storedKey{}}, nil
	}
	if err != nil {
		return keysFile{}, err
	}
	var file keysFile
	if err := json.Unmarshal(body, &file); err != nil {
		return keysFile{}, err
	}
	if file.Keys == nil {
		file.Keys = map[string]storedKey{}
	}
	return file, nil
}

// saveKeys replaces the file atomically, 0600, before the change is reported:
// a turn started right after the response must find the key.
func (s *Service) saveKeys(file keysFile) error {
	path := s.keysPath()
	if path == "" {
		return errors.New("key storage is not configured")
	}
	body, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(body, '\n')); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// maskKey keeps the last four characters, enough to tell two keys apart.
func maskKey(value string) string {
	if len(value) <= 4 {
		return "…"
	}
	return "…" + value[len(value)-4:]
}

type keySummary struct {
	Name    string `json:"name"`
	Last4   string `json:"last4"`
	Updated string `json:"updated,omitempty"`
}

// listKeys answers GET /v1/keys.
func (s *Service) listKeys(admin bool) (int, any) {
	if !admin {
		return http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	file, err := s.loadKeys()
	if err != nil {
		return http.StatusInternalServerError, map[string]string{"error": err.Error()}
	}
	names := make([]string, 0, len(file.Keys))
	for name := range file.Keys {
		names = append(names, name)
	}
	sort.Strings(names)
	keys := make([]keySummary, 0, len(names))
	for _, name := range names {
		entry := file.Keys[name]
		summary := keySummary{Name: name, Last4: maskKey(entry.Value)}
		if entry.Updated > 0 {
			summary.Updated = time.Unix(entry.Updated, 0).Format(time.RFC3339)
		}
		keys = append(keys, summary)
	}
	return http.StatusOK, map[string]any{"keys": keys, "stored": s.keysPath() != ""}
}

// putKey answers PUT /v1/keys/<NAME> with {"value": "..."}.
func (s *Service) putKey(name string, body []byte, admin bool, now time.Time) (int, any) {
	if !admin {
		return http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	name = strings.TrimSpace(name)
	if !keyVar.MatchString(name) {
		return http.StatusBadRequest, map[string]string{
			"error": "a key name looks like OPENAI_API_KEY",
		}
	}
	var in struct {
		Value string `json:"value"`
	}
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	value := strings.TrimSpace(in.Value)
	if value == "" {
		return http.StatusBadRequest, map[string]string{"error": "the key is empty"}
	}
	if len(value) > 4096 {
		return http.StatusBadRequest, map[string]string{"error": "the key is too long"}
	}
	if keyValueProblem.MatchString(value) {
		return http.StatusBadRequest, map[string]string{
			"error": "the key has a control character in it",
		}
	}
	file, err := s.loadKeys()
	if err != nil {
		return http.StatusInternalServerError, map[string]string{"error": err.Error()}
	}
	file.Keys[name] = storedKey{Value: value, Updated: now.Unix()}
	if err := s.saveKeys(file); err != nil {
		return http.StatusInternalServerError, map[string]string{"error": err.Error()}
	}
	return http.StatusOK, keySummary{Name: name, Last4: maskKey(value), Updated: now.Format(time.RFC3339)}
}

// deleteKey answers DELETE /v1/keys/<NAME>.
func (s *Service) deleteKey(name string, admin bool) (int, any) {
	if !admin {
		return http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	file, err := s.loadKeys()
	if err != nil {
		return http.StatusInternalServerError, map[string]string{"error": err.Error()}
	}
	if _, ok := file.Keys[name]; !ok {
		return http.StatusNotFound, map[string]string{"error": "no such key"}
	}
	delete(file.Keys, name)
	if err := s.saveKeys(file); err != nil {
		return http.StatusInternalServerError, map[string]string{"error": err.Error()}
	}
	return http.StatusOK, map[string]any{"removed": name}
}
