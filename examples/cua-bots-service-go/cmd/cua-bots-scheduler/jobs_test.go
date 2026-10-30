// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"strings"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func TestJobAdminAddsListsPausesAndRemoves(t *testing.T) {
	s := domain.NewScheduler("cli")
	t0 := time.Unix(1_800_000_000, 0).UTC()

	out, err := jobAdmin{add: "alpha", title: "Digest", prompt: "Summarize", every: time.Hour, now: t0}.apply(s)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || !strings.HasPrefix(out[0], "ADDED ") {
		t.Fatalf("add: %v", out)
	}
	if len(s.Jobs) != 1 {
		t.Fatalf("the job was not registered: %d", len(s.Jobs))
	}

	out, err = jobAdmin{list: true}.apply(s)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 1 || !strings.Contains(out[0], "state=active") || !strings.Contains(out[0], "bot=alpha") {
		t.Fatalf("list: %v", out)
	}

	id := ""
	for k := range s.Jobs {
		id = k
	}
	if _, err := (jobAdmin{pause: id}).apply(s); err != nil {
		t.Fatal(err)
	}
	if !s.Jobs[id].Paused {
		t.Fatal("pause did not take effect")
	}
	if _, err := (jobAdmin{resume: id}).apply(s); err != nil {
		t.Fatal(err)
	}
	if s.Jobs[id].Paused {
		t.Fatal("resume did not take effect")
	}
	if _, err := (jobAdmin{remove: id}).apply(s); err != nil {
		t.Fatal(err)
	}
	if len(s.Jobs) != 0 {
		t.Fatal("remove did not take effect")
	}
}

func TestJobAdminRefusesIncompleteOrUnknownCommands(t *testing.T) {
	s := domain.NewScheduler("cli")
	if _, err := (jobAdmin{add: "alpha", every: time.Hour}).apply(s); err == nil {
		t.Fatal("a job without a prompt must be refused")
	}
	if _, err := (jobAdmin{add: "alpha", prompt: "x", every: time.Second}).apply(s); err == nil {
		t.Fatal("a cadence below a minute must be refused")
	}
	if _, err := (jobAdmin{pause: "nope"}).apply(s); err == nil {
		t.Fatal("pausing an unknown job must fail")
	}
	if _, err := (jobAdmin{remove: "nope"}).apply(s); err == nil {
		t.Fatal("removing an unknown job must fail")
	}
	out, err := jobAdmin{list: true}.apply(s)
	if err != nil || len(out) != 1 || out[0] != "no jobs" {
		t.Fatalf("empty list: %v %v", out, err)
	}
}
