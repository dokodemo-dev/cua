// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
)

// turnRunner runs one chat turn by handing it to cua-bot-turn, which owns the
// Cua CLI call, the run id and the harness.
//
// Only the turn's own words go to the browser: the CLI's progress notices and
// warnings land on stderr, and are kept for the failure message instead, so a
// chat turn reads like a reply rather than an install log.
func turnRunner(
	command string,
	timeout time.Duration,
	space func(string) string,
	agent func(string) (api.AgentSettings, bool),
) api.TurnRunner {
	return func(turnID, botID, prompt string, write func(string)) error {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, command)
		env := append(os.Environ(),
			"CUA_BOTS_BOT_ID="+botID,
			"CUA_BOTS_PROMPT="+prompt,
			"CUA_BOT_MODE=wait",
		)
		// The Bot's own Space wins over the host-wide default, so two Bots
		// created from the browser never share one computer by accident.
		if space != nil {
			if id := space(botID); id != "" {
				env = append(env, "CUA_BOTS_SPACE="+id)
			}
		}
		// A Bot with its own agent settings overrides the host-wide defaults
		// completely; an empty value means "let the Space decide", which is why
		// the variables are set even when empty.
		if agent != nil {
			settings, ok := agent(botID)
			env = append(env, agentEnv(settings, ok)...)
		}
		cmd.Env = env
		pipe, err := cmd.StdoutPipe()
		if err != nil {
			return fmt.Errorf("turn pipe: %w", err)
		}
		tail := &tailBuffer{limit: 8 << 10}
		cmd.Stderr = tail
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("turn start: %w", err)
		}
		scanner := bufio.NewScanner(pipe)
		scanner.Buffer(make([]byte, 0, 64<<10), 1<<20)
		for scanner.Scan() {
			write(scanner.Text() + "\n")
		}
		err = cmd.Wait()
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("turn timed out after %s", timeout)
		}
		if err != nil {
			if reason := tail.lastLine(); reason != "" {
				return fmt.Errorf("%s", reason)
			}
			return fmt.Errorf("turn exited: %w", err)
		}
		return nil
	}
}

// agentEnv is the environment cua-bot-turn reads for one Bot's settings, with
// its time windows resolved for this moment. Exported for a test: the values
// are not secrets, only variable names.
func agentEnv(settings api.AgentSettings, ok bool) []string {
	if !ok {
		return nil
	}
	active, _ := api.ResolveAgent(settings, time.Now())
	env := api.AgentEnv(active, true)
	return []string{
		"CUA_BOTS_HARNESS=" + env["CUA_BOTS_HARNESS"],
		"CUA_BOT_MODEL=" + env["CUA_BOT_MODEL"],
		"CUA_BOT_BASE_URL=" + env["CUA_BOT_BASE_URL"],
		"CUA_BOT_WIRE=" + env["CUA_BOT_WIRE"],
		"CUA_BOT_KEY_VARS=" + env["CUA_BOT_KEY_VARS"],
		"CUA_BOT_HEADERS=" + env["CUA_BOT_HEADERS"],
	}
}

// tailBuffer keeps the last few kilobytes written to it, so a failure can say
// why without keeping a whole log in memory.
type tailBuffer struct {
	mu    sync.Mutex
	data  bytes.Buffer
	limit int
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.data.Write(p)
	if t.data.Len() > t.limit {
		kept := t.data.Bytes()[t.data.Len()-t.limit:]
		t.data.Reset()
		t.data.Write(kept)
	}
	return len(p), nil
}

// lastLine is the most specific thing the process said, which is what the
// browser should show when a turn fails.
func (t *tailBuffer) lastLine() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	lines := bytes.Split(bytes.TrimSpace(t.data.Bytes()), []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		line := string(bytes.TrimSpace(lines[i]))
		if line != "" {
			return line
		}
	}
	return ""
}
