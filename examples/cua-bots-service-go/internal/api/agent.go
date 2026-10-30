// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// AgentSettings is how one Bot's turns start: which harness, which model, and
// (for API providers) which endpoint and host variables to forward.
//
// It never holds a secret. Keys stay in the host environment (turn.env); this
// records only their variable names, which the turn script forwards with
// --env-from-host.
type AgentSettings struct {
	Harness  string   `json:"harness,omitempty"`  // pi (default), openai-codex, claude-code, ...
	Provider string   `json:"provider,omitempty"` // UI preset: space, openai, anthropic, openrouter, custom
	Model    string   `json:"model,omitempty"`
	BaseURL  string   `json:"baseURL,omitempty"`
	Wire     string   `json:"wire,omitempty"` // anthropic, openai-responses, openai-chat, gemini
	KeyVars  []string `json:"keyVars,omitempty"`
	// Headers are extra request headers the endpoint needs, such as
	// x-opencode-session on OpenCode Go. Values are not secrets.
	Headers map[string]string `json:"headers,omitempty"`
	// Windows switch the Bot to another provider by time of day, so it can
	// stay on a provider's discounted hours. The first match wins; a Bot
	// without one uses the fields above at every hour.
	Windows []AgentWindow `json:"windows,omitempty"`
}

func (a AgentSettings) empty() bool {
	return a.Harness == "" && a.Provider == "" && a.Model == "" && a.BaseURL == "" &&
		a.Wire == "" && len(a.KeyVars) == 0 && len(a.Headers) == 0 &&
		len(a.Windows) == 0
}

var (
	agentHarnesses = map[string]bool{
		"pi": true, "openai-codex": true, "claude-code": true, "gemini-cli": true,
		"google-antigravity": true, "opencode": true, "goose": true,
		"deepseek-harness": true, "hermes": true, "openclaw": true,
	}
	agentProviders = map[string]bool{
		"space": true, "openai": true, "anthropic": true, "openrouter": true,
		"deepseek": true, "ollama": true, "opencode": true, "dsh": true,
		"custom": true,
	}
	agentWires = map[string]bool{
		"anthropic": true, "openai-responses": true, "openai-chat": true, "gemini": true,
	}
	modelName  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$`)
	keyVar     = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
	headerName = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,63}$`)
)

// AgentFor reports a Bot's own settings. A Bot without an entry follows the
// host-wide defaults in turn.env; a Bot with one overrides them completely, so
// an empty model means "use the Space's own default", not "fall back".
func (s *Service) AgentFor(botID string) (AgentSettings, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value, ok := s.agents[botID]
	return value, ok
}

// AgentEnv is the environment cua-bot-turn reads for one Bot's settings. The
// values are variable names and model ids, never secrets.
func AgentEnv(settings AgentSettings, ok bool) map[string]string {
	if !ok {
		return nil
	}
	harness := settings.Harness
	if harness == "" {
		harness = "pi"
	}
	return map[string]string{
		"CUA_BOTS_HARNESS": harness,
		"CUA_BOT_MODEL":    settings.Model,
		"CUA_BOT_BASE_URL": settings.BaseURL,
		"CUA_BOT_WIRE":     settings.Wire,
		"CUA_BOT_KEY_VARS": strings.Join(settings.KeyVars, ","),
		"CUA_BOT_HEADERS":  headerArgString(settings.Headers),
	}
}

// headerArgString renders headers as `name=value` pairs the turn script splits
// on `;`. Validation keeps both separators out of the values.
func headerArgString(headers map[string]string) string {
	names := make([]string, 0, len(headers))
	for name := range headers {
		names = append(names, name)
	}
	sort.Strings(names)
	pairs := make([]string, 0, len(names))
	for _, name := range names {
		pairs = append(pairs, name+"="+headers[name])
	}
	return strings.Join(pairs, ";")
}

// agentEnvFor answers GET /v1/bots/<id>/agent/env: the settings a scheduled
// delivery must use at this moment, windows resolved. Without it a routine
// would follow turn.env while the same Bot's chat turns followed its own
// settings.
func (s *Service) agentEnvFor(botID string, now time.Time) (int, any) {
	value, ok := s.agents[botID]
	if !ok {
		return http.StatusOK, map[string]any{"set": false}
	}
	active, label := ResolveAgent(value, now)
	payload := map[string]any{"set": true, "name": label, "env": AgentEnv(active, true)}
	if until, next := NextChange(value, now); !until.IsZero() {
		payload["until"] = until.Format(time.RFC3339)
		payload["next"] = next
	}
	return http.StatusOK, payload
}

func (s *Service) getAgent(botID string, now time.Time) (int, any) {
	value, ok := s.agents[botID]
	payload := map[string]any{"agent": value, "set": ok, "scheduleText": scheduleText(value.Windows)}
	if ok {
		active, label := ResolveAgent(value, now)
		payload["active"] = active
		payload["activeName"] = label
		if until, next := NextChange(value, now); !until.IsZero() {
			payload["until"] = until.Format(time.RFC3339)
			payload["next"] = next
		}
	}
	return http.StatusOK, payload
}

func (s *Service) putAgent(botID string, body []byte, admin bool) (int, any) {
	if !admin {
		return http.StatusForbidden, map[string]string{"error": "not an administrator"}
	}
	var in AgentSettings
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	// The UI edits the windows as lines; this is the one place they are read.
	var extra struct {
		ScheduleText *string `json:"scheduleText"`
	}
	_ = json.Unmarshal(body, &extra)
	if extra.ScheduleText != nil {
		windows, problem := parseScheduleText(*extra.ScheduleText)
		if problem != "" {
			return http.StatusBadRequest, map[string]string{"error": problem}
		}
		in.Windows = windows
	}
	clean, problem := normalizeAgent(in)
	if problem != "" {
		return http.StatusBadRequest, map[string]string{"error": problem}
	}
	if s.agents == nil {
		s.agents = map[string]AgentSettings{}
	}
	// An all-empty body means "follow the host defaults", which is the absence
	// of an entry rather than an entry with empty fields.
	if clean.empty() {
		delete(s.agents, botID)
	} else {
		s.agents[botID] = clean
	}
	if err := s.resetRuns(botID); err != nil {
		return http.StatusInternalServerError, map[string]string{"error": "could not reset the run: " + err.Error()}
	}
	return http.StatusOK, map[string]any{
		"agent": clean, "set": !clean.empty(),
		"scheduleText": scheduleText(clean.Windows),
	}
}

func normalizeAgent(in AgentSettings) (AgentSettings, string) {
	out := AgentSettings{
		Harness:  strings.TrimSpace(in.Harness),
		Provider: strings.TrimSpace(in.Provider),
		Model:    strings.TrimSpace(in.Model),
		BaseURL:  strings.TrimSpace(in.BaseURL),
		Wire:     strings.TrimSpace(in.Wire),
	}
	if out.Harness != "" && !agentHarnesses[out.Harness] {
		return AgentSettings{}, "unknown harness"
	}
	if out.Provider != "" && !agentProviders[out.Provider] {
		return AgentSettings{}, "unknown provider preset"
	}
	if out.Wire != "" && !agentWires[out.Wire] {
		return AgentSettings{}, "unknown wire format"
	}
	if out.Wire != "" && out.BaseURL == "" {
		return AgentSettings{}, "a wire format needs a base URL"
	}
	if out.Model != "" && !modelName.MatchString(out.Model) {
		return AgentSettings{}, "model must be 1-128 characters (letters, digits, . _ : / @ + -)"
	}
	if out.BaseURL != "" {
		lower := strings.ToLower(out.BaseURL)
		if !strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://") {
			return AgentSettings{}, "base URL must start with http:// or https://"
		}
		if len(out.BaseURL) > 512 {
			return AgentSettings{}, "base URL is too long"
		}
	}
	if len(in.Headers) > 4 {
		return AgentSettings{}, "at most 4 headers"
	}
	for name, value := range in.Headers {
		name = strings.TrimSpace(name)
		value = strings.TrimSpace(value)
		if !headerName.MatchString(name) {
			return AgentSettings{}, "header names must look like x-opencode-session"
		}
		if value == "" || len(value) > 256 {
			return AgentSettings{}, "a header value must be 1-256 characters"
		}
		if strings.ContainsAny(name, " \t") || strings.ContainsAny(value, "\r\n") {
			return AgentSettings{}, "headers with spaces or newlines are not allowed"
		}
		if out.Headers == nil {
			out.Headers = map[string]string{}
		}
		out.Headers[name] = value
	}
	seen := map[string]bool{}
	for _, name := range in.KeyVars {
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			continue
		}
		if !keyVar.MatchString(name) {
			return AgentSettings{}, "key variables must be uppercase names such as OPENAI_API_KEY"
		}
		seen[name] = true
		out.KeyVars = append(out.KeyVars, name)
		if len(out.KeyVars) > 4 {
			return AgentSettings{}, "at most 4 key variables"
		}
	}
	windows, problem := normalizeSchedule(in.Windows)
	if problem != "" {
		return AgentSettings{}, problem
	}
	out.Windows = windows
	return out, ""
}

// agentsCopyLocked copies the map for Snapshot, which already holds the lock.
func (s *Service) agentsCopyLocked() map[string]AgentSettings {
	if len(s.agents) == 0 {
		return nil
	}
	out := make(map[string]AgentSettings, len(s.agents))
	for id, settings := range s.agents {
		out[id] = settings
	}
	return out
}

// resetRuns forgets a Bot's stored run ids so the next turn starts a new run
// with the new settings. The turn script keeps one file per Space.
func (s *Service) resetRuns(botID string) error {
	if s.RunsDir == "" {
		return nil
	}
	entries, err := os.ReadDir(s.RunsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, botID+".") || !strings.HasSuffix(name, ".run") {
			continue
		}
		if err := os.Remove(filepath.Join(s.RunsDir, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}
