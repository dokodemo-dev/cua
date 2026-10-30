// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"testing"
	"time"
)

func jst(t *testing.T, s string) time.Time {
	t.Helper()
	loc := agentZone()
	at, err := time.ParseInLocation("2006-01-02 15:04", s, loc)
	if err != nil {
		t.Fatalf("%s: %v", s, err)
	}
	return at
}

// The windows a Bot needs to stay on discounted hours: Ollama Cloud is at peak
// on weekdays between 12:00 and 18:00 UTC (21:00-03:00 JST), and OpenCode Go is
// off-peak then.
func offPeakWindows(t *testing.T) []AgentWindow {
	t.Helper()
	windows, problem := parseScheduleText(`mon-fri 21:00-24:00 opencode
tue-sat 00:00-03:00 opencode
* ollama`)
	if problem != "" {
		t.Fatalf("parse: %s", problem)
	}
	clean, problem := normalizeSchedule(windows)
	if problem != "" {
		t.Fatalf("normalize: %s", problem)
	}
	return clean
}

func TestOffPeakWindowsFollowBothProvidersHours(t *testing.T) {
	windows := offPeakWindows(t)
	settings := AgentSettings{Provider: "ollama", Windows: windows}

	cases := []struct {
		at   string
		want string
	}{
		// Ollama Cloud peak (weekday nights): OpenCode Go picks it up.
		{"2026-10-27 21:00", "opencode"}, // Tue 12:00 UTC
		{"2026-10-27 23:59", "opencode"},
		{"2026-10-28 00:00", "opencode"}, // Wed 15:00 UTC, still peak
		{"2026-10-28 02:59", "opencode"},
		{"2026-10-30 21:30", "opencode"}, // Fri 12:30 UTC
		// Ollama Cloud off-peak: the day, the weekend, and the JST morning.
		{"2026-10-28 03:00", "ollama"}, // Wed 18:00 UTC, peak ends
		{"2026-10-28 13:00", "ollama"}, // Wed 04:00 UTC (OpenCode lunch off-peak)
		{"2026-10-28 14:59", "ollama"},
		{"2026-10-28 20:59", "ollama"},
		{"2026-10-26 00:30", "ollama"}, // Mon 00:30 JST is Sun 15:30 UTC, off-peak
		{"2026-10-31 00:30", "opencode"},
		{"2026-10-31 03:00", "ollama"}, // Sat
		{"2026-10-31 22:00", "ollama"}, // Sat 13:00 UTC, weekend
		{"2026-11-01 12:00", "ollama"}, // Sun
	}
	for _, c := range cases {
		_, got := ResolveAgent(settings, jst(t, c.at))
		if got != c.want {
			t.Errorf("%s: got %s, want %s", c.at, got, c.want)
		}
	}
}

func TestAWindowTakesItsPresetsFields(t *testing.T) {
	settings := AgentSettings{
		Provider: "custom",
		Harness:  "pi",
		Model:    "gpt-6.1-sol",
		Windows:  offPeakWindows(t),
	}
	active, name := ResolveAgent(settings, jst(t, "2026-10-28 12:00"))
	if name != "ollama" {
		t.Fatalf("name: %s", name)
	}
	if active.Model != "deepseek-v4.1-flash:1017" || active.BaseURL != "https://ollama.com/v1" {
		t.Fatalf("ollama fields: %+v", active)
	}
	if len(active.KeyVars) != 1 || active.KeyVars[0] != "OLLAMA_API_KEY" {
		t.Fatalf("key vars: %+v", active.KeyVars)
	}
	if len(active.Windows) != 0 {
		t.Fatal("the resolved settings must not carry the windows")
	}

	night, name := ResolveAgent(settings, jst(t, "2026-10-27 22:00"))
	if name != "opencode" {
		t.Fatalf("name: %s", name)
	}
	if night.Headers["x-opencode-session"] == "" {
		t.Fatalf("headers: %+v", night.Headers)
	}
	// OpenCode Go publishes the same build without a tag.
	if night.Model != "deepseek-v4.1-flash" {
		t.Fatalf("opencode model: %s", night.Model)
	}
	if len(night.KeyVars) != 1 || night.KeyVars[0] != "OPENCODE_API_KEY" {
		t.Fatalf("key vars: %+v", night.KeyVars)
	}
}

func TestNextChangeNamesTheSwitch(t *testing.T) {
	settings := AgentSettings{Windows: offPeakWindows(t)}
	until, next := NextChange(settings, jst(t, "2026-10-27 20:59"))
	if next != "opencode" {
		t.Fatalf("next: %s", next)
	}
	if got := until.In(agentZone()).Format("15:04"); got != "21:00" {
		t.Fatalf("until: %s", got)
	}
	until, next = NextChange(settings, jst(t, "2026-10-28 02:59"))
	if next != "ollama" {
		t.Fatalf("next: %s", next)
	}
	if got := until.In(agentZone()).Format("15:04"); got != "03:00" {
		t.Fatalf("until: %s", got)
	}
}

func TestScheduleTextRoundTrips(t *testing.T) {
	windows := offPeakWindows(t)
	text := scheduleText(windows)
	again, problem := parseScheduleText(text)
	if problem != "" {
		t.Fatalf("parse: %s", problem)
	}
	clean, problem := normalizeSchedule(again)
	if problem != "" {
		t.Fatalf("normalize: %s", problem)
	}
	if len(clean) != len(windows) {
		t.Fatalf("%d windows, want %d", len(clean), len(windows))
	}
	if text != "mon,tue,wed,thu,fri 21:00-24:00 opencode\ntue,wed,thu,fri,sat 00:00-03:00 opencode\n* ollama" {
		t.Fatalf("text: %q", text)
	}
	// Day ranges and single days read the same way.
	for _, in := range []string{"mon-fri 10:00-13:00 ollama", "mon,wed ollama", "* ollama"} {
		w, problem := parseScheduleText(in)
		if problem != "" {
			t.Fatalf("%s: %s", in, problem)
		}
		if _, problem := normalizeSchedule(w); problem != "" {
			t.Fatalf("%s: %s", in, problem)
		}
	}
}

func TestBadWindowsAreRefused(t *testing.T) {
	for _, in := range []string{
		"mon-fri 21:00 opencode",       // no end time
		"mon-fri 25:00-26:00 opencode", // not a clock
		"mon-fri 21:00-21:00 opencode", // empty window
		"funday 10:00-11:00 ollama",    // not a day
		"mon-fri 10:00-11:00 nope",     // not a preset
		"mon-fri 10:00-11:00 ollama extra",
	} {
		windows, problem := parseScheduleText(in)
		if problem == "" {
			_, problem = normalizeSchedule(windows)
		}
		if problem == "" {
			t.Fatalf("%s was accepted", in)
		}
	}
	// A window cannot name a key variable the Bot layer would not accept.
	_, problem := normalizeSchedule([]AgentWindow{{
		Preset: "ollama", KeyVars: []string{"not a name"},
	}})
	if problem == "" {
		t.Fatal("a bad key variable was accepted")
	}
}
