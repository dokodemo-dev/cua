// SPDX-License-Identifier: FSL-1.1-MIT

package domain_test

import (
	"errors"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func registry(t *testing.T) domain.Registry {
	t.Helper()
	r := domain.NewRegistry()
	if err := r.AddTarget(domain.ExecutionTarget{ID: "local", Name: "This machine", Kind: domain.KindLocal}); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestSharedSpaceRefusesAnotherTrustGroup(t *testing.T) {
	r := registry(t)
	err := r.AddBinding(domain.SpaceBinding{
		SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared, TrustGroup: "team-a",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Assign("first", "local:shared", "/bots/first", "team-a"); err != nil {
		t.Fatal(err)
	}
	if err := r.Assign("second", "local:shared", "/bots/second", "team-b"); !errors.Is(err, domain.ErrTrustGroupMismatch) {
		t.Fatalf("want trust group mismatch, got %v", err)
	}
	if err := r.Assign("second", "local:shared", "/bots/second", "team-a"); err != nil {
		t.Fatal(err)
	}
	if got := r.Bindings["local:shared"].BotIDs(); len(got) != 2 {
		t.Fatalf("want two bots, got %v", got)
	}
}

func TestExclusiveSpaceAndDeletionRights(t *testing.T) {
	r := registry(t)
	if err := r.AddBinding(domain.SpaceBinding{
		SpaceID: "local:owned", TargetID: "local", Mode: domain.ModeExclusive, ManagedByApp: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := r.Assign("first", "local:owned", "/bots/first", "default"); err != nil {
		t.Fatal(err)
	}
	if err := r.Assign("second", "local:owned", "/bots/second", "default"); !errors.Is(err, domain.ErrExclusiveSpaceOccupied) {
		t.Fatalf("want exclusive space occupied, got %v", err)
	}
	effect, err := r.Detach("first", "local:owned")
	if err != nil {
		t.Fatal(err)
	}
	if effect != domain.DeleteOwnedSpace {
		t.Fatalf("an owned exclusive space may be deleted, got %v", effect)
	}
	if err := r.ConfirmOwnedSpaceDeleted("local:owned"); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Bindings["local:owned"]; ok {
		t.Fatal("binding should be gone")
	}
}

func TestOverlappingWorkspacesAreRefused(t *testing.T) {
	r := registry(t)
	_ = r.AddBinding(domain.SpaceBinding{SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared})
	if err := r.Assign("first", "local:shared", "/bots/first", "default"); err != nil {
		t.Fatal(err)
	}
	if err := r.Assign("second", "local:shared", "/bots/first/child", "default"); !errors.Is(err, domain.ErrOverlappingWorkspace) {
		t.Fatalf("want overlap, got %v", err)
	}
	if err := r.Assign("second", "local:shared", "/bots/../first", "default"); !errors.Is(err, domain.ErrInvalidWorkspace) {
		t.Fatalf("want invalid workspace, got %v", err)
	}
}

func TestScreenLeaseIsExclusiveAndExpires(t *testing.T) {
	r := registry(t)
	_ = r.AddBinding(domain.SpaceBinding{SpaceID: "local:shared", TargetID: "local", Mode: domain.ModeShared})
	_ = r.Assign("first", "local:shared", "/bots/first", "default")
	_ = r.Assign("second", "local:shared", "/bots/second", "default")
	now := float64(time.Now().Unix())
	first, err := r.AcquireScreen("first", "local:shared", now, 10)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.AcquireScreen("second", "local:shared", now, 10); !errors.Is(err, domain.ErrScreenBusy) {
		t.Fatalf("want screen busy, got %v", err)
	}
	second, err := r.AcquireScreen("second", "local:shared", now+10, 10)
	if err != nil {
		t.Fatalf("an expired lease must be takeable: %v", err)
	}
	if err := r.ReleaseScreen("first", "local:shared", first.ID); !errors.Is(err, domain.ErrStaleLease) {
		t.Fatalf("want stale lease, got %v", err)
	}
	if !r.ScreenAllowed("second", "local:shared", second.ID, now+11) {
		t.Fatal("the holder may use the screen while the lease is alive")
	}
	if r.ScreenAllowed("second", "local:shared", second.ID, now+20) {
		t.Fatal("an expired lease must not allow the screen")
	}
}
