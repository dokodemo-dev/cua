// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
)

// cuaProvisioner makes a Space for a Bot with the cua CLI: create the sandbox,
// then register it, the same two steps an operator runs by hand. Nothing here
// is required for a Bot that already has a Space; it only keeps "create a Bot"
// from ending in "Space not found" on the first message.
func cuaProvisioner(binary string, timeout time.Duration) func(ctx context.Context, botID, spaceID string) error {
	return func(ctx context.Context, botID, spaceID string) error {
		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		name := spaceName(spaceID)
		if name == "" {
			return fmt.Errorf("space %q is not a local space", spaceID)
		}
		create := []string{"sb", "create", "linux", "--on", "local", "--kind", "container", "--name", name}
		if out, err := runCua(ctx, binary, create...); err != nil {
			// A Space that already exists is the state we wanted.
			if !strings.Contains(out, "already exists") {
				return fmt.Errorf("cua sb create: %v: %s", err, lastLine(out))
			}
		}
		if out, err := runCua(ctx, binary, "spaces", "add", spaceID); err != nil {
			if !strings.Contains(out, "already") {
				return fmt.Errorf("cua spaces add: %v: %s", err, lastLine(out))
			}
		}
		return nil
	}
}

// spaceName turns "local:bot-gamma" into "bot-gamma": the sandbox name the CLI
// takes. Anything not local is refused rather than guessed at.
func spaceName(spaceID string) string {
	rest, ok := strings.CutPrefix(spaceID, "local:")
	if !ok {
		if strings.Contains(spaceID, ":") {
			return ""
		}
		return strings.TrimSpace(spaceID)
	}
	return strings.TrimSpace(rest)
}

// cuaSpaceLister asks the CLI which Spaces exist, so the browser can offer them
// by name instead of asking the operator to recall an id.
func cuaSpaceLister(binary string, timeout time.Duration, parse func([]byte) ([]api.SpaceInfo, error)) api.SpaceLister {
	return func(ctx context.Context) ([]api.SpaceInfo, error) {
		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		out, err := runCua(ctx, binary, "spaces", "ls", "--json", "--no-size")
		if err != nil {
			return nil, fmt.Errorf("cua spaces ls: %v: %s", err, lastLine(out))
		}
		return parse([]byte(out))
	}
}

func runCua(ctx context.Context, binary string, args ...string) (string, error) {
	if binary == "" {
		return "", errors.New("no cua binary configured")
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.Env = append(os.Environ(), "CUA_TELEMETRY=0", "DO_NOT_TRACK=1")
	err := cmd.Run()
	return out.String(), err
}

func lastLine(out string) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) == 0 {
		return ""
	}
	return strings.TrimSpace(lines[len(lines)-1])
}
