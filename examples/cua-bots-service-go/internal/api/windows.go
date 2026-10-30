// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"fmt"
	"strings"
	"time"
)

// expandWindow fills a window from its preset and checks it.
func expandWindow(w AgentWindow) (AgentWindow, string) {
	out := AgentWindow{Days: w.Days, From: w.From, To: w.To, Preset: w.Preset}
	if w.Preset != "" {
		p, ok := agentPresets[w.Preset]
		if !ok {
			return AgentWindow{}, fmt.Sprintf("unknown preset %q", w.Preset)
		}
		out.Harness, out.Model, out.BaseURL, out.Wire = p.Harness, p.Model, p.BaseURL, p.Wire
		out.KeyVars = append([]string(nil), p.KeyVars...)
		if p.Headers != nil {
			out.Headers = map[string]string{}
			for k, v := range p.Headers {
				out.Headers[k] = v
			}
		}
	}
	if v := strings.TrimSpace(w.Harness); v != "" {
		out.Harness = v
	}
	if v := strings.TrimSpace(w.Model); v != "" {
		out.Model = v
	}
	if v := strings.TrimSpace(w.BaseURL); v != "" {
		out.BaseURL = v
	}
	if v := strings.TrimSpace(w.Wire); v != "" {
		out.Wire = v
	}
	if len(w.KeyVars) > 0 {
		out.KeyVars = w.KeyVars
	}
	if len(w.Headers) > 0 {
		out.Headers = w.Headers
	}
	// The same checks a Bot's own settings get.
	check := AgentSettings{
		Harness: out.Harness, Model: out.Model, BaseURL: out.BaseURL,
		Wire: out.Wire, KeyVars: out.KeyVars, Headers: out.Headers,
	}
	if _, problem := normalizeAgent(check); problem != "" {
		return AgentWindow{}, problem
	}
	for i, d := range out.Days {
		d = strings.ToLower(strings.TrimSpace(d))
		if dayIndex(d) < 0 {
			return AgentWindow{}, fmt.Sprintf("unknown day %q (use mon, tue, ...)", d)
		}
		out.Days[i] = d
	}
	if (out.From == "") != (out.To == "") {
		return AgentWindow{}, "a window needs both a start and an end time"
	}
	if out.From != "" {
		from, err := clockMinutes(out.From)
		if err != nil {
			return AgentWindow{}, err.Error()
		}
		to, err := clockMinutes(out.To)
		if err != nil {
			return AgentWindow{}, err.Error()
		}
		if from == to {
			return AgentWindow{}, "a window cannot start and end at the same time"
		}
	}
	return out, ""
}

// ResolveAgent applies the first window that covers at over settings. It also
// returns the window that applied: its preset name, "custom" for a window
// without one, or "settings" when no window applied.
func ResolveAgent(settings AgentSettings, at time.Time) (AgentSettings, string) {
	at = at.In(agentZone())
	for _, w := range settings.Windows {
		if !matchWindow(w, at) {
			continue
		}
		out := settings
		out.Windows = nil
		if w.Harness != "" {
			out.Harness = w.Harness
		}
		if w.Model != "" {
			out.Model = w.Model
		}
		if w.BaseURL != "" {
			out.BaseURL = w.BaseURL
		}
		if w.Wire != "" {
			out.Wire = w.Wire
		}
		out.KeyVars = nil
		if len(w.KeyVars) > 0 {
			out.KeyVars = w.KeyVars
		}
		out.Headers = nil
		if len(w.Headers) > 0 {
			out.Headers = w.Headers
		}
		label := w.Preset
		if label == "" {
			label = "custom"
		}
		out.Provider = label
		return out, label
	}
	return settings, "settings"
}

// NextChange is when the applied window stops applying, and which one applies
// then. It looks a day ahead at most, which is enough: windows repeat daily.
func NextChange(settings AgentSettings, at time.Time) (time.Time, string) {
	at = at.In(agentZone()).Truncate(time.Minute)
	_, label := ResolveAgent(settings, at)
	for i := 1; i <= 24*60; i++ {
		step := at.Add(time.Duration(i) * time.Minute)
		if _, next := ResolveAgent(settings, step); next != label {
			return step, next
		}
	}
	return time.Time{}, label
}

// normalizeSchedule expands and checks every window.
func normalizeSchedule(in []AgentWindow) ([]AgentWindow, string) {
	if len(in) > 8 {
		return nil, "at most 8 time windows"
	}
	out := make([]AgentWindow, 0, len(in))
	for _, w := range in {
		clean, problem := expandWindow(w)
		if problem != "" {
			return nil, problem
		}
		out = append(out, clean)
	}
	return out, ""
}
