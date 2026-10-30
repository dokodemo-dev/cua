// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// AgentWindow switches a Bot to another provider inside a time of day. Windows
// exist because the providers price their hours differently: Ollama Cloud is
// half price outside 12:00-18:00 UTC on weekdays, and OpenCode Go's DeepSeek
// models are half price outside 01:00-04:00 and 06:00-10:00 UTC on weekdays.
// The two sets of peak hours do not overlap, so a Bot can hold the discounted
// rate all day by switching provider instead of paying the peak price.
//
// A window carries the same fields as AgentSettings and overrides them while it
// applies; a window that only names a Preset takes that preset's fields. No
// value here is confidential: provider keys stay in turn.env, named by KeyVars.
type AgentWindow struct {
	// Days it applies to: mon, tue, ... (empty: every day).
	Days []string `json:"days,omitempty"`
	// From and To are "HH:MM" in the service zone. To may be "24:00", and a To
	// earlier than From wraps past midnight. Both empty: all day.
	From string `json:"from,omitempty"`
	To   string `json:"to,omitempty"`
	// Preset names one of agentPresets (ollama, opencode, ...).
	Preset  string            `json:"preset,omitempty"`
	Harness string            `json:"harness,omitempty"`
	Model   string            `json:"model,omitempty"`
	BaseURL string            `json:"baseURL,omitempty"`
	Wire    string            `json:"wire,omitempty"`
	KeyVars []string          `json:"keyVars,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
}

// preset is one of the provider presets the Web UI offers, spelled the same way
// so a window can name it instead of repeating every field.
type preset struct {
	Harness string
	Model   string
	BaseURL string
	Wire    string
	KeyVars []string
	Headers map[string]string
}

// agentPresets is the server's copy of the UI presets. A window naming one takes
// these fields unless it sets its own.
var agentPresets = map[string]preset{
	"space":     {Harness: "pi"},
	"openai":    {Harness: "openai-codex", KeyVars: []string{"OPENAI_API_KEY"}},
	"anthropic": {Harness: "claude-code", KeyVars: []string{"ANTHROPIC_API_KEY"}},
	"openrouter": {
		Harness: "pi", BaseURL: "https://openrouter.ai/api/v1", Wire: "openai-chat",
		KeyVars: []string{"OPENROUTER_API_KEY"},
	},
	"deepseek": {
		Harness: "pi", Model: "deepseek-chat",
		BaseURL: "https://api.deepseek.com/v1", Wire: "openai-chat",
		KeyVars: []string{"DEEPSEEK_API_KEY"},
	},
	// Ollama Cloud serves DeepSeek V4.1 Flash at half price off-peak. The tag
	// picks the 1017 build; OpenCode Go publishes the same build untagged.
	"ollama": {
		Harness: "pi", Model: "deepseek-v4.1-flash:1017",
		BaseURL: "https://ollama.com/v1", Wire: "openai-chat",
		KeyVars: []string{"OLLAMA_API_KEY"},
	},
	// OpenCode Go serves the same model behind a session header.
	"opencode": {
		Harness: "pi", Model: "deepseek-v4.1-flash",
		BaseURL: "https://opencode.ai/zen/go/v1", Wire: "openai-chat",
		KeyVars: []string{"OPENCODE_API_KEY"},
		Headers: map[string]string{"x-opencode-session": "cua-bots"},
	},
	"dsh": {Harness: "deepseek-harness", KeyVars: []string{"DEEPSEEK_API_KEY"}},
}

var weekdayNames = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}

// agentZone is where windows are read: the user thinks in JST, and both
// providers state their hours in UTC.
func agentZone() *time.Location {
	loc, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		return time.FixedZone("JST", 9*60*60)
	}
	return loc
}

// matchWindow reports whether w covers at (given in the service zone).
func matchWindow(w AgentWindow, at time.Time) bool {
	if len(w.Days) > 0 {
		day := weekdayNames[int(at.Weekday())]
		found := false
		for _, d := range w.Days {
			if d == day {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	if w.From == "" && w.To == "" {
		return true
	}
	from, err := clockMinutes(w.From)
	if err != nil {
		return false
	}
	to, err := clockMinutes(w.To)
	if err != nil {
		return false
	}
	now := at.Hour()*60 + at.Minute()
	if from <= to {
		return now >= from && now < to
	}
	// Past midnight: the window wraps, so the day it names holds both ends.
	return now >= from || now < to
}

// clockMinutes reads "HH:MM" (24:00 allowed as an end).
func clockMinutes(s string) (int, error) {
	hour, rest, ok := strings.Cut(s, ":")
	if !ok {
		return 0, fmt.Errorf("time %q wants HH:MM", s)
	}
	h, err := strconv.Atoi(strings.TrimSpace(hour))
	if err != nil || h < 0 || h > 24 {
		return 0, fmt.Errorf("time %q wants HH:MM", s)
	}
	m, err := strconv.Atoi(strings.TrimSpace(rest))
	if err != nil || m < 0 || m > 59 || (h == 24 && m != 0) {
		return 0, fmt.Errorf("time %q wants HH:MM", s)
	}
	return h*60 + m, nil
}
