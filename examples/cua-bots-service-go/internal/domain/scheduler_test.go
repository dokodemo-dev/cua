// SPDX-License-Identifier: FSL-1.1-MIT

package domain_test

import (
	"errors"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func TestASlotIsClaimedExactlyOnce(t *testing.T) {
	s := domain.NewScheduler("svc-a")
	t0 := time.Unix(1_800_000_000, 0).UTC()
	job, err := s.AddJob("alpha", "Digest", "Summarize", 3600, t0.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.AcquireLease(t0, 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	if claims, _ := s.ClaimDue(t0, 10); len(claims) != 0 {
		t.Fatalf("nothing is due yet, got %v", claims)
	}
	claims, err := s.ClaimDue(t0.Add(time.Minute), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(claims) != 1 {
		t.Fatalf("want one claim, got %d", len(claims))
	}
	want := domain.DeliveryKey(job, t0.Add(time.Minute))
	if claims[0].Key != want {
		t.Fatalf("key: got %q want %q", claims[0].Key, want)
	}
	if again, _ := s.ClaimDue(t0.Add(time.Minute), 10); len(again) != 0 {
		t.Fatalf("a claimed slot must not repeat, got %v", again)
	}
	if err := s.MarkDelivered(claims[0].Key, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if s.Deliveries[claims[0].Key].State != domain.DeliveryDelivered {
		t.Fatal("the slot must be delivered")
	}
	// The first slot was t0+60s; the next is one cadence later.
	if next := s.Jobs[job].NextRunAt; next != float64(t0.Add(60*time.Second+3600*time.Second).Unix()) {
		t.Fatalf("the job must move to the next slot, got %v", next)
	}
}

func TestACrashLeavesTheSlotUnconfirmedAndNothingResendsIt(t *testing.T) {
	s := domain.NewScheduler("svc-a")
	t0 := time.Unix(1_800_000_000, 0).UTC()
	if _, err := s.AddJob("alpha", "Digest", "Summarize", 600, t0.Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := s.AcquireLease(t0, 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	claims, _ := s.ClaimDue(t0.Add(10*time.Second), 1)
	if len(claims) != 1 {
		t.Fatal("want one claim")
	}
	// The process died: the claim is older than the timeout.
	s.ReclaimExpired(t0.Add(10*time.Second + 121*time.Second))
	if state := s.Deliveries[claims[0].Key].State; state != domain.DeliveryUnconfirmed {
		t.Fatalf("want unconfirmed, got %s", state)
	}
	if got := s.Unresolved(); len(got) != 1 {
		t.Fatalf("the slot must stay unresolved, got %v", got)
	}
	if again, _ := s.ClaimDue(t0.Add(200*time.Second), 10); len(again) != 0 {
		t.Fatalf("an unconfirmed slot must not be resent automatically, got %v", again)
	}
	// Only an explicit ack resends it, once.
	if err := s.Acknowledge(claims[0].Key, true, t0.Add(201*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := s.AcquireLease(t0.Add(202*time.Second), 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	resent, _ := s.ClaimDue(t0.Add(202*time.Second), 10)
	if len(resent) != 1 || resent[0].Attempt != 2 {
		t.Fatalf("want one resend as attempt 2, got %v", resent)
	}
	if more, _ := s.ClaimDue(t0.Add(203*time.Second), 10); len(more) != 0 {
		t.Fatalf("the resend happens once, got %v", more)
	}
}

func TestOnlyTheLeaseHolderClaimsAndAnExpiredLeaseCanBeTakenOver(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0).UTC()
	first := domain.NewScheduler("svc-a")
	if _, err := first.AddJob("alpha", "Digest", "Summarize", 600, t0.Add(10*time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := first.AcquireLease(t0, 60*time.Second); err != nil {
		t.Fatal(err)
	}
	claims, _ := first.ClaimDue(t0.Add(10*time.Second), 1)
	if len(claims) != 1 {
		t.Fatal("want one claim")
	}
	// A second process reads the same file while the first lease is alive.
	second := *first
	second.OwnerID = "svc-b"
	if err := second.AcquireLease(t0.Add(30*time.Second), time.Minute); !errors.Is(err, domain.ErrLeaseHeld) {
		t.Fatalf("want lease held, got %v", err)
	}
	// After it expires, svc-b takes over and the old claim is unconfirmed.
	if err := second.AcquireLease(t0.Add(61*time.Second), time.Minute); err != nil {
		t.Fatal(err)
	}
	if state := second.Deliveries[claims[0].Key].State; state != domain.DeliveryUnconfirmed {
		t.Fatalf("the old owner's claim must be unconfirmed, got %s", state)
	}
	if err := first.MarkDelivered(claims[0].Key, t0.Add(62*time.Second)); !errors.Is(err, domain.ErrLeaseLost) {
		t.Fatalf("the old owner must lose the lease, got %v", err)
	}
	if _, err := first.ClaimDue(t0.Add(62*time.Second), 1); !errors.Is(err, domain.ErrLeaseLost) {
		t.Fatalf("the old owner must not claim, got %v", err)
	}
}

func TestPausedJobsAreSkipped(t *testing.T) {
	s := domain.NewScheduler("svc-a")
	t0 := time.Unix(1_800_000_000, 0).UTC()
	job, err := s.AddJob("alpha", "Digest", "Summarize", 600, t0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddJob("alpha", "Fast", "x", 0, t0); !errors.Is(err, domain.ErrInvalidCadence) {
		t.Fatalf("want invalid cadence, got %v", err)
	}
	s.SetPaused(job, true)
	if err := s.AcquireLease(t0, time.Minute); err != nil {
		t.Fatal(err)
	}
	if claims, _ := s.ClaimDue(t0, 10); len(claims) != 0 {
		t.Fatalf("paused jobs do not run, got %v", claims)
	}
	s.SetPaused(job, false)
	if claims, _ := s.ClaimDue(t0, 10); len(claims) != 1 {
		t.Fatalf("the resumed job runs, got %v", claims)
	}
}

func TestRemovingAJobDropsItsPendingSlots(t *testing.T) {
	s := domain.NewScheduler("svc-a")
	t0 := time.Unix(1_800_000_000, 0).UTC()
	keep, err := s.AddJob("alpha", "Keep", "Keep going", 3600, t0)
	if err != nil {
		t.Fatal(err)
	}
	drop, err := s.AddJob("beta", "Drop", "Drop this", 3600, t0)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.AcquireLease(t0, 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	if claims, err := s.ClaimDue(t0, 10); err != nil || len(claims) != 2 {
		t.Fatalf("both jobs are due: %v %v", claims, err)
	}

	if err := s.RemoveJob(drop); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Jobs[drop]; ok {
		t.Fatal("the job is still registered")
	}
	for key, delivery := range s.Deliveries {
		if delivery.JobID == drop {
			t.Fatalf("delivery %s of the removed job is still queued", key)
		}
	}
	if _, ok := s.Jobs[keep]; !ok {
		t.Fatal("removing one job must keep the others")
	}
	if err := s.RemoveJob("nope"); !errors.Is(err, domain.ErrUnknownJob) {
		t.Fatalf("removing an unknown job: %v", err)
	}
}
