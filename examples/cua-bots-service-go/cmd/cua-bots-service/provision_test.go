// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSpaceNameOnlyAcceptsLocalSpaces(t *testing.T) {
	cases := map[string]string{
		"local:bot-gamma": "bot-gamma",
		"local:bot alpha": "bot alpha",
		"bot-gamma":       "bot-gamma",
		"cloud:remote":    "",
		"":                "",
	}
	for in, want := range cases {
		if got := spaceName(in); got != want {
			t.Fatalf("spaceName(%q) = %q, want %q", in, got, want)
		}
	}
}

// The provisioner must run the same two commands an operator runs by hand, in
// that order, and stop when the first one fails for a reason other than an
// existing Space.
func TestProvisionerCreatesThenRegistersTheSpace(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	fake := filepath.Join(dir, "cua")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + log + "\nexit 0\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	run := cuaProvisioner(fake, time.Minute)
	if err := run(context.Background(), "gamma", "local:bot-gamma"); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(body)), "\n")
	if len(lines) != 2 {
		t.Fatalf("want create then add, got %v", lines)
	}
	if lines[0] != "sb create linux --on local --kind container --name bot-gamma" {
		t.Fatalf("create: %s", lines[0])
	}
	if lines[1] != "spaces add local:bot-gamma" {
		t.Fatalf("add: %s", lines[1])
	}
}

func TestProvisionerReportsWhyItFailed(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "cua")
	script := "#!/bin/sh\necho 'error: no space left on device' >&2\nexit 1\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	err := cuaProvisioner(fake, time.Minute)(context.Background(), "gamma", "local:bot-gamma")
	if err == nil || !strings.Contains(err.Error(), "no space left on device") {
		t.Fatalf("the reason must reach the browser: %v", err)
	}
}

func TestProvisionerRefusesANonLocalSpace(t *testing.T) {
	err := cuaProvisioner("/bin/true", time.Minute)(context.Background(), "g", "cloud:somewhere")
	if err == nil {
		t.Fatal("a cloud space must not be built locally")
	}
}
