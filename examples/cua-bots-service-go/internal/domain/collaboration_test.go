// SPDX-License-Identifier: FSL-1.1-MIT

package domain_test

import (
	"errors"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func collab(t *testing.T) (*domain.Collaboration, domain.Principal) {
	t.Helper()
	r := registry(t)
	if err := r.AddBinding(domain.SpaceBinding{
		SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared, TrustGroup: "team-a",
	}); err != nil {
		t.Fatal(err)
	}
	for _, bot := range []string{"alpha", "beta", "gamma", "delta", "epsilon"} {
		if err := r.Assign(bot, "local:shared", "/bots/"+bot, "team-a"); err != nil {
			t.Fatal(err)
		}
	}
	c := domain.NewCollaboration(r)
	space := "local:shared"
	caps := map[domain.Capability]bool{}
	for _, cap := range domain.BotCapabilities {
		caps[cap] = true
	}
	return c, domain.Principal{BotID: "alpha", TrustGroup: "team-a", SpaceID: space, Capabilities: caps}
}

func TestRetryingWithTheSameKeyReturnsTheSameTask(t *testing.T) {
	c, alpha := collab(t)
	now := time.Unix(1_800_000_000, 0)
	first, err := c.Delegate(alpha, "beta", "local:shared", "Summarize", "req-1", nil, now, now.Add(5*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	second, err := c.Delegate(alpha, "beta", "local:shared", "Summarize", "req-1", nil, now, now.Add(5*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if first.Task.ID != second.Task.ID || second.Fresh {
		t.Fatalf("a repeated key must return the same task, fresh=%v", second.Fresh)
	}
	if _, err := c.Delegate(alpha, "gamma", "local:shared", "Other", "req-1", nil, now, now.Add(time.Minute)); !errors.Is(err, domain.ErrIdempotencyConflict) {
		t.Fatalf("want conflict, got %v", err)
	}
}

func TestDelegationNeverLoopsAndStopsAtDepthThree(t *testing.T) {
	c, alpha := collab(t)
	now := time.Unix(1_800_000_000, 0)
	beta := alpha
	beta.BotID = "beta"
	gamma := alpha
	gamma.BotID = "gamma"

	first, err := c.Delegate(alpha, "beta", "local:shared", "step 1", "a", nil, now, now.Add(10*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if first.Task.Depth != 1 {
		t.Fatalf("want depth 1, got %d", first.Task.Depth)
	}
	second, err := c.Delegate(beta, "gamma", "local:shared", "step 2", "b", &first.Task.ID, now, now.Add(10*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if second.Task.Depth != 2 {
		t.Fatalf("want depth 2, got %d", second.Task.Depth)
	}
	if _, err := c.Delegate(gamma, "alpha", "local:shared", "loop", "c", &second.Task.ID, now, now.Add(time.Minute)); !errors.Is(err, domain.ErrDelegationLoop) {
		t.Fatalf("want loop refusal, got %v", err)
	}
	third, err := c.Delegate(gamma, "delta", "local:shared", "step 3", "c2", &second.Task.ID, now, now.Add(10*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if third.Task.Depth != 3 {
		t.Fatalf("want depth 3, got %d", third.Task.Depth)
	}
	delta := alpha
	delta.BotID = "delta"
	if _, err := c.Delegate(delta, "epsilon", "local:shared", "too deep", "d", &third.Task.ID, now, now.Add(time.Minute)); !errors.Is(err, domain.ErrDepthExceeded) {
		t.Fatalf("want depth refusal, got %v", err)
	}
}

func TestConcurrencyAndDeadlineAreBounded(t *testing.T) {
	c, alpha := collab(t)
	now := time.Unix(1_800_000_000, 0)
	for i, bot := range []string{"beta", "gamma", "delta", "epsilon"} {
		if _, err := c.Delegate(alpha, bot, "local:shared", "work", "g"+string(rune('0'+i)), nil, now, now.Add(10*time.Minute)); err != nil {
			t.Fatalf("delegation %d: %v", i, err)
		}
	}
	if _, err := c.Delegate(alpha, "beta", "local:shared", "overflow", "over", nil, now, now.Add(time.Minute)); !errors.Is(err, domain.ErrConcurrencyLimit) {
		t.Fatalf("want concurrency limit, got %v", err)
	}

	c2, alpha2 := collab(t)
	parent, err := c2.Delegate(alpha2, "beta", "local:shared", "parent", "p", nil, now, now.Add(2*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	beta := alpha2
	beta.BotID = "beta"
	child, err := c2.Delegate(beta, "gamma", "local:shared", "child", "ch", &parent.Task.ID, now, now.Add(30*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if child.Task.Deadline != parent.Task.Deadline {
		t.Fatalf("a child deadline must not outlive its parent: %v vs %v", child.Task.Deadline, parent.Task.Deadline)
	}
	c2.Expire(now.Add(2 * time.Minute))
	if err := c2.Complete(parent.Task.ID, "late", now.Add(3*time.Minute)); !errors.Is(err, domain.ErrTaskExpired) {
		t.Fatalf("want expired refusal, got %v", err)
	}
	if got := c2.Deliverable("alpha", now.Add(3*time.Minute)); len(got) != 0 {
		t.Fatalf("an expired result must not be delivered, got %v", got)
	}
}

func TestArtifactsAreOwnedAndBounded(t *testing.T) {
	c, alpha := collab(t)
	now := time.Unix(1_800_000_000, 0)
	if _, err := c.RegisterArtifact(alpha, "local:shared", "report.md", 2048, "digest", now); err != nil {
		t.Fatal(err)
	}
	if _, err := c.RegisterArtifact(alpha, "local:shared", "huge.bin", 8*1024*1024+1, "digest", now); !errors.Is(err, domain.ErrArtifactTooLarge) {
		t.Fatalf("want too large, got %v", err)
	}
	if _, err := c.RegisterArtifact(alpha, "local:shared", "../escape", 10, "digest", now); !errors.Is(err, domain.ErrInvalidArtifactName) {
		t.Fatalf("want invalid name, got %v", err)
	}
	beta := alpha
	beta.BotID = "beta"
	if got := c.Artifacts(beta.BotID); len(got) != 1 {
		t.Fatalf("a member sees the artifact, got %d", len(got))
	}
}

func TestMessagesReachMembersOnly(t *testing.T) {
	c, alpha := collab(t)
	now := time.Unix(1_800_000_000, 0)
	note, err := c.Post(alpha, "local:shared", "Standup at 10", nil, "n1", now)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.Deliverable("beta", now); len(got) != 1 || got[0].ID != note.ID {
		t.Fatalf("beta should see the note, got %v", got)
	}
	if got := c.Deliverable("alpha", now); len(got) != 0 {
		t.Fatalf("a sender does not receive its own note, got %v", got)
	}
	to := "beta"
	direct, err := c.Post(alpha, "local:shared", "Ping", &to, "n2", now)
	if err != nil {
		t.Fatal(err)
	}
	if got := c.Deliverable("gamma", now); len(got) != 1 {
		t.Fatalf("gamma sees only the broadcast, got %v", got)
	}
	if got := c.Deliverable("beta", now); len(got) != 2 || got[1].ID != direct.ID {
		t.Fatalf("beta sees both, got %v", got)
	}
}
