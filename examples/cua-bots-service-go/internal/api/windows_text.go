// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"fmt"
	"strings"
)

// scheduleText renders windows in the one-line form the Web UI edits:
//
//	mon-fri 21:00-24:00 opencode
//	* ollama
func scheduleText(windows []AgentWindow) string {
	lines := make([]string, 0, len(windows))
	for _, w := range windows {
		days := "*"
		if len(w.Days) > 0 {
			days = strings.Join(w.Days, ",")
		}
		when := days
		if w.From != "" {
			when = days + " " + w.From + "-" + w.To
		}
		lines = append(lines, strings.TrimSpace(when+" "+w.Preset))
	}
	return strings.Join(lines, "\n")
}

// parseScheduleText reads the one-line form: "<when> <preset>" per line, where
// <when> is `*`, a day list, or a day list and "HH:MM-HH:MM".
func parseScheduleText(text string) ([]AgentWindow, string) {
	var out []AgentWindow
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return nil, fmt.Sprintf("%q wants \"<when> <preset>\"", line)
		}
		w := AgentWindow{Preset: fields[len(fields)-1]}
		switch len(fields) {
		case 2:
			if fields[0] != "*" {
				w.Days = splitDays(fields[0])
			}
		case 3:
			w.Days = splitDays(fields[0])
			from, to, ok := strings.Cut(fields[1], "-")
			if !ok {
				return nil, fmt.Sprintf("%q wants HH:MM-HH:MM", line)
			}
			w.From, w.To = from, to
		default:
			return nil, fmt.Sprintf("%q has too many fields", line)
		}
		out = append(out, w)
	}
	return out, ""
}

// splitDays reads "mon-fri", "mon,wed" or "*" into day names.
func splitDays(s string) []string {
	if s == "*" {
		return nil
	}
	var days []string
	for _, part := range strings.Split(s, ",") {
		part = strings.ToLower(strings.TrimSpace(part))
		if part == "" {
			continue
		}
		from, to, ok := strings.Cut(part, "-")
		if !ok {
			days = append(days, part)
			continue
		}
		start, end := dayIndex(from), dayIndex(to)
		if start < 0 || end < 0 {
			days = append(days, part)
			continue
		}
		for i := start; ; i = (i + 1) % 7 {
			days = append(days, weekdayNames[i])
			if i == end {
				break
			}
		}
	}
	// Weekday order, without repeats: the UI renders them as they came.
	seen := map[string]bool{}
	ordered := days[:0]
	for _, d := range days {
		if !seen[d] {
			seen[d] = true
			ordered = append(ordered, d)
		}
	}
	return ordered
}

func dayIndex(name string) int {
	for i, d := range weekdayNames {
		if d == name {
			return i
		}
	}
	return -1
}
