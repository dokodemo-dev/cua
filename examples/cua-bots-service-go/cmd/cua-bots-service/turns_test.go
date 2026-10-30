// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
)

// The browser should see the reply, not the CLI's progress notes. Those go to
// stderr; on success they are dropped, on failure the last line becomes the
// error the chat shows.
func TestTurnOutputGoesToTheBrowserAndNoiseStaysOut(t *testing.T) {
	script := writeScript(t, `
printf '[install] pi cached\n' >&2
printf 'REPLY-OK\n'
printf 'warning: something harmless\n' >&2
`)
	var seen strings.Builder
	run := turnRunner(script, 10*time.Second, nil, nil)
	if err := run("turn-1", "alpha", "hi", func(s string) { seen.WriteString(s) }); err != nil {
		t.Fatalf("turn failed: %v", err)
	}
	if !strings.Contains(seen.String(), "REPLY-OK") {
		t.Fatalf("the reply did not reach the browser: %q", seen.String())
	}
	if strings.Contains(seen.String(), "[install]") || strings.Contains(seen.String(), "warning:") {
		t.Fatalf("stderr reached the browser: %q", seen.String())
	}
}

func TestAFailingTurnSaysWhyInTheLastLine(t *testing.T) {
	script := writeScript(t, `
printf 'partial output\n'
printf 'warning: noise first\n' >&2
printf 'error: the agent is not signed in yet\n' >&2
exit 1
`)
	run := turnRunner(script, 10*time.Second, nil, nil)
	err := run("turn-1", "alpha", "hi", func(string) {})
	if err == nil {
		t.Fatal("a failing turn must return an error")
	}
	if !strings.Contains(err.Error(), "not signed in yet") {
		t.Fatalf("the reason was lost: %v", err)
	}
	if strings.Contains(err.Error(), "warning") {
		t.Fatalf("the error should be the last thing said: %v", err)
	}
}

func TestTheTurnRunsInTheBotsOwnSpace(t *testing.T) {
	script := writeScript(t, `
printf 'space=%s\n' "$CUA_BOTS_SPACE"
printf 'mode=%s\n' "$CUA_BOT_MODE"
`)
	var seen strings.Builder
	run := turnRunner(script, 10*time.Second, func(bot string) string {
		if bot != "alpha" {
			t.Fatalf("asked for the space of %q", bot)
		}
		return "local:bot-alpha"
	}, nil)
	if err := run("turn-1", "alpha", "hi", func(s string) { seen.WriteString(s) }); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(seen.String(), "space=local:bot-alpha") {
		t.Fatalf("the Space was not passed: %q", seen.String())
	}
	if !strings.Contains(seen.String(), "mode=wait") {
		t.Fatalf("the runner must ask for a finished turn: %q", seen.String())
	}
}

func TestPerBotAgentSettingsReachTheTurn(t *testing.T) {
	script := writeScript(t, `
printf '%s|%s|%s|%s|%s\n' "$CUA_BOTS_HARNESS" "$CUA_BOT_MODEL" "$CUA_BOT_BASE_URL" "$CUA_BOT_WIRE" "$CUA_BOT_KEY_VARS"
`)
	var seen strings.Builder
	lookup := func(string) (api.AgentSettings, bool) {
		return api.AgentSettings{
			Harness: "pi", Model: "gpt-6.1-sol",
			BaseURL: "https://example.test/v1",
			Wire:    "openai-chat",
			KeyVars: []string{"OPENAI_API_KEY", "OPENROUTER_API_KEY"},
		}, true
	}
	run := turnRunner(script, 10*time.Second, nil, lookup)
	if err := run("turn-1", "alpha", "hi", func(s string) { seen.WriteString(s) }); err != nil {
		t.Fatalf("turn failed: %v", err)
	}
	want := "pi|gpt-6.1-sol|https://example.test/v1|openai-chat|OPENAI_API_KEY,OPENROUTER_API_KEY"
	if !strings.Contains(seen.String(), want) {
		t.Fatalf("agent env did not reach the turn: %q", seen.String())
	}
}

// A Bot without its own settings keeps the host-wide values from turn.env.
func TestUnsetAgentSettingsAddNothing(t *testing.T) {
	if got := agentEnv(api.AgentSettings{}, false); got != nil {
		t.Fatalf("expected no overrides, got %v", got)
	}
	got := agentEnv(api.AgentSettings{}, true)
	if len(got) != 6 || got[0] != "CUA_BOTS_HARNESS=pi" || got[1] != "CUA_BOT_MODEL=" {
		t.Fatalf("a saved empty setting should clear the host default: %v", got)
	}
}

func TestATimedOutTurnSaysSo(t *testing.T) {
	script := writeScript(t, `
sleep 5
`)
	run := turnRunner(script, 200*time.Millisecond, nil, nil)
	err := run("turn-1", "alpha", "hi", func(string) {})
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("want a timeout, got %v", err)
	}
}

// writeScript writes an executable shell script with the given body.
func writeScript(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "turn.sh")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}
