// SPDX-License-Identifier: FSL-1.1-MIT

// Package domain holds the execution and collaboration state: who owns a Space,
// which Bot may do what, and what was delegated. It is the Go counterpart of
// CuaBotsCore's ExecutionRegistry, AuthorizationPolicy and CollaborationService,
// and keeps the same JSON shape so a state file can move between the two.
package domain

import (
	"errors"
	"fmt"
	"math"
	"path"
	"sort"
	"strings"
)

// Errors are the same refusals the Swift policy makes.
var (
	ErrInvalidIdentity        = errors.New("invalid identity")
	ErrInvalidWorkspace       = errors.New("invalid workspace")
	ErrOverlappingWorkspace   = errors.New("overlapping workspace")
	ErrDuplicateTarget        = errors.New("duplicate target")
	ErrDuplicateBinding       = errors.New("duplicate binding")
	ErrUnknownTarget          = errors.New("unknown target")
	ErrUnknownSpace           = errors.New("unknown space")
	ErrExclusiveSpaceOccupied = errors.New("exclusive space occupied")
	ErrBotNotAssigned         = errors.New("bot not assigned")
	ErrBotAlreadyAssigned     = errors.New("bot already assigned")
	ErrScreenBusy             = errors.New("screen busy")
	ErrStaleLease             = errors.New("stale lease")
	ErrInvalidLeaseDuration   = errors.New("invalid lease duration")
	ErrTrustGroupMismatch     = errors.New("trust group mismatch")
)

// TargetKind is where a Space runs.
type TargetKind string

const (
	KindLocal       TargetKind = "local"
	KindDirect      TargetKind = "direct"
	KindLegacyCloud TargetKind = "legacyCloud"
)

// ExecutionTarget is metadata only: credentials stay in a reference, never here.
type ExecutionTarget struct {
	ID                  string     `json:"id"`
	Name                string     `json:"name"`
	Kind                TargetKind `json:"kind"`
	Endpoint            string     `json:"endpoint,omitempty"`
	CredentialReference string     `json:"credentialReference,omitempty"`
}

// ScreenLease lets exactly one Bot drive the screen until it expires.
type ScreenLease struct {
	ID        string  `json:"id"`
	BotID     string  `json:"botID"`
	ExpiresAt float64 `json:"expiresAt"` // Unix seconds, as Swift's Date encodes
	raw       string  // the original ISO-8601 form, kept for round trips
}

// BindingMode says whether a Space belongs to one Bot or is shared.
type BindingMode string

const (
	ModeExclusive BindingMode = "exclusive"
	ModeShared    BindingMode = "shared"
)

// SpaceBinding is the ownership record for one Space.
type SpaceBinding struct {
	SpaceID      string            `json:"spaceID"`
	TargetID     string            `json:"targetID"`
	Mode         BindingMode       `json:"mode"`
	ManagedByApp bool              `json:"managedByApp"`
	TrustGroup   string            `json:"trustGroup"`
	Workspaces   map[string]string `json:"workspaces"`
	ScreenLease  *ScreenLease      `json:"screenLease,omitempty"`
}

// BotIDs is every Bot assigned to the Space.
func (b SpaceBinding) BotIDs() []string {
	ids := make([]string, 0, len(b.Workspaces))
	for id := range b.Workspaces {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Group is the trust group with the empty value defaulted, so records written
// before the field existed stay readable.
func (b SpaceBinding) Group() string {
	if strings.TrimSpace(b.TrustGroup) == "" {
		return "default"
	}
	return b.TrustGroup
}

// DetachEffect says what deleting the Bot must do to its Space.
type DetachEffect string

const (
	Preserve         DetachEffect = "preserve"
	DeleteOwnedSpace DetachEffect = "deleteOwnedSpace"
)

// Registry is the ownership policy. Callers serialize mutations.
type Registry struct {
	Targets  map[string]ExecutionTarget `json:"targets"`
	Bindings map[string]SpaceBinding    `json:"bindings"`
	// Avatars is the Bot's face: the colour, eyes and ears the web UI draws.
	// It is appearance only; nothing about execution reads it.
	Avatars map[string]Avatar `json:"avatars,omitempty"`
	// Archived Bots keep their Space, workspace and history, so that putting
	// one back is a decision without side effects. Archiving is not deletion:
	// deleting would have to decide what happens to the Space.
	Archived map[string]bool `json:"archived,omitempty"`
}

// NewRegistry returns an empty registry.
func NewRegistry() Registry {
	return Registry{Targets: map[string]ExecutionTarget{}, Bindings: map[string]SpaceBinding{}}
}

func (r *Registry) ensure() {
	if r.Targets == nil {
		r.Targets = map[string]ExecutionTarget{}
	}
	if r.Bindings == nil {
		r.Bindings = map[string]SpaceBinding{}
	}
}

// AddTarget registers an execution host once.
func (r *Registry) AddTarget(t ExecutionTarget) error {
	r.ensure()
	if t.ID == "" || strings.ContainsRune(t.ID, 0) {
		return ErrInvalidIdentity
	}
	if _, ok := r.Targets[t.ID]; ok {
		return ErrDuplicateTarget
	}
	r.Targets[t.ID] = t
	return nil
}

// Move points a Bot at another Space, keeping its workspace path. It is the fix
// for a registry that names a Space the Bot does not actually run in.
func (r *Registry) Move(botID, spaceID string) error {
	r.ensure()
	workspace, ok := r.workspaceOf(botID)
	if !ok {
		return ErrInvalidIdentity
	}
	target, ok := r.Bindings[spaceID]
	if !ok {
		return ErrUnknownSpace
	}
	for sid, b := range r.Bindings {
		if sid == spaceID {
			continue
		}
		if _, has := b.Workspaces[botID]; has {
			delete(b.Workspaces, botID)
			r.Bindings[sid] = b
		}
	}
	if target.Workspaces == nil {
		target.Workspaces = map[string]string{}
	}
	target.Workspaces[botID] = workspace
	r.Bindings[spaceID] = target
	return nil
}

// Avatar is a Bot's appearance. The values are the names the koala design
// uses, so the Swift app and the web UI draw the same face.
type Avatar struct {
	Color string `json:"color"`
	Eyes  string `json:"eyes"`
	Ears  string `json:"ears"`
}

// AvatarColors, AvatarEyes and AvatarEars are the allowed values.
var (
	AvatarColors = []string{"violet", "orange", "sky", "cloud", "slate", "graphite"}
	AvatarEyes   = []string{"star", "round", "happy", "calm", "plus", "delight"}
	AvatarEars   = []string{"scalloped", "round", "small"}
)

// DefaultAvatar picks a colour from the name, so a new Bot never needs a
// choice: the same rule the Swift app uses.
func DefaultAvatar(name string) Avatar {
	sum := 0
	for _, r := range name {
		sum += int(r)
	}
	if sum < 0 {
		sum = -sum
	}
	return Avatar{Color: AvatarColors[sum%len(AvatarColors)], Eyes: "star", Ears: "scalloped"}
}

// Normalise fills in what was left out and rejects values the design does not
// have, so a typo cannot reach the renderer.
func (a Avatar) Normalise(name string) (Avatar, error) {
	out := a
	if out.Color == "" {
		out.Color = DefaultAvatar(name).Color
	}
	if out.Eyes == "" {
		out.Eyes = "star"
	}
	if out.Ears == "" {
		out.Ears = "scalloped"
	}
	if !contains(AvatarColors, out.Color) || !contains(AvatarEyes, out.Eyes) || !contains(AvatarEars, out.Ears) {
		return Avatar{}, ErrInvalidIdentity
	}
	return out, nil
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// SetAvatar records a Bot's appearance.
func (r *Registry) SetAvatar(botID string, avatar Avatar) error {
	r.ensure()
	if _, ok := r.workspaceOf(botID); !ok {
		return ErrInvalidIdentity
	}
	normalised, err := avatar.Normalise(botID)
	if err != nil {
		return err
	}
	if r.Avatars == nil {
		r.Avatars = map[string]Avatar{}
	}
	r.Avatars[botID] = normalised
	return nil
}

// AvatarOf returns a Bot's appearance, defaulting from its name.
func (r Registry) AvatarOf(botID string) Avatar {
	if a, ok := r.Avatars[botID]; ok {
		return a
	}
	return DefaultAvatar(botID)
}

// Archive hides a Bot and remembers that it is on the shelf. It refuses an
// unknown Bot, so a typo cannot look like success.
func (r *Registry) Archive(botID string) error {
	r.ensure()
	if _, ok := r.workspaceOf(botID); !ok {
		return ErrInvalidIdentity
	}
	if r.Archived == nil {
		r.Archived = map[string]bool{}
	}
	r.Archived[botID] = true
	return nil
}

// Unarchive puts a Bot back.
func (r *Registry) Unarchive(botID string) error {
	r.ensure()
	if _, ok := r.workspaceOf(botID); !ok {
		return ErrInvalidIdentity
	}
	delete(r.Archived, botID)
	return nil
}

// IsArchived reports whether a Bot is on the shelf.
func (r Registry) IsArchived(botID string) bool { return r.Archived[botID] }

func (r Registry) workspaceOf(botID string) (string, bool) {
	for _, b := range r.Bindings {
		if workspace, ok := b.Workspaces[botID]; ok {
			return workspace, true
		}
	}
	return "", false
}

// AddBinding registers a Space once.
func (r *Registry) AddBinding(b SpaceBinding) error {
	r.ensure()
	if b.SpaceID == "" || strings.ContainsRune(b.SpaceID, 0) {
		return ErrInvalidIdentity
	}
	if _, ok := r.Targets[b.TargetID]; !ok {
		return ErrUnknownTarget
	}
	if _, ok := r.Bindings[b.SpaceID]; ok {
		return ErrDuplicateBinding
	}
	if b.Workspaces == nil {
		b.Workspaces = map[string]string{}
	}
	r.Bindings[b.SpaceID] = b
	return nil
}

// Assign puts a Bot in a Space, refusing a foreign trust group, a taken
// exclusive Space, a second Space, and workspaces that overlap by path prefix.
func (r *Registry) Assign(botID, spaceID, workspace, trustGroup string) error {
	r.ensure()
	if botID == "" || !ValidAgentName(botID) {
		return ErrInvalidIdentity
	}
	binding, ok := r.Bindings[spaceID]
	if !ok {
		return ErrUnknownSpace
	}
	clean, err := ValidWorkspace(workspace)
	if err != nil {
		return err
	}
	if binding.Mode == ModeShared && normalizeGroup(trustGroup) != binding.Group() {
		return ErrTrustGroupMismatch
	}
	for other, b := range r.Bindings {
		if other == spaceID {
			continue
		}
		if _, taken := b.Workspaces[botID]; taken {
			return ErrBotAlreadyAssigned
		}
	}
	if binding.Mode == ModeExclusive {
		for id := range binding.Workspaces {
			if id != botID {
				return ErrExclusiveSpaceOccupied
			}
		}
	}
	for other, existing := range binding.Workspaces {
		if other == botID {
			continue
		}
		if clean == existing || strings.HasPrefix(clean, existing+"/") ||
			strings.HasPrefix(existing, clean+"/") {
			return ErrOverlappingWorkspace
		}
	}
	if binding.Workspaces == nil {
		binding.Workspaces = map[string]string{}
	}
	binding.Workspaces[botID] = clean
	r.Bindings[spaceID] = binding
	return nil
}

// Detach removes a Bot and says whether its Space may now be deleted.
func (r *Registry) Detach(botID, spaceID string) (DetachEffect, error) {
	binding, ok := r.Bindings[spaceID]
	if !ok {
		return Preserve, ErrUnknownSpace
	}
	if _, assigned := binding.Workspaces[botID]; !assigned {
		return Preserve, ErrBotNotAssigned
	}
	delete(binding.Workspaces, botID)
	if binding.ScreenLease != nil && binding.ScreenLease.BotID == botID {
		binding.ScreenLease = nil
	}
	r.Bindings[spaceID] = binding
	if binding.ManagedByApp && binding.Mode == ModeExclusive && len(binding.Workspaces) == 0 {
		return DeleteOwnedSpace, nil
	}
	return Preserve, nil
}

// ConfirmOwnedSpaceDeleted forgets a binding only after the SDK deleted it.
func (r *Registry) ConfirmOwnedSpaceDeleted(spaceID string) error {
	binding, ok := r.Bindings[spaceID]
	if !ok {
		return ErrUnknownSpace
	}
	if !binding.ManagedByApp || binding.Mode != ModeExclusive || len(binding.Workspaces) != 0 {
		return ErrExclusiveSpaceOccupied
	}
	delete(r.Bindings, spaceID)
	return nil
}

// AcquireScreen takes the screen lease for a member Bot, at most five minutes.
func (r *Registry) AcquireScreen(botID, spaceID string, now float64, durationSeconds float64) (ScreenLease, error) {
	if !finite(durationSeconds) || durationSeconds <= 0 || durationSeconds > 300 || !finite(now) {
		return ScreenLease{}, ErrInvalidLeaseDuration
	}
	binding, ok := r.Bindings[spaceID]
	if !ok {
		return ScreenLease{}, ErrUnknownSpace
	}
	if _, member := binding.Workspaces[botID]; !member {
		return ScreenLease{}, ErrBotNotAssigned
	}
	if binding.ScreenLease != nil && binding.ScreenLease.ExpiresAt > now {
		return ScreenLease{}, ErrScreenBusy
	}
	lease := newScreenLease(botID, now, durationSeconds)
	binding.ScreenLease = &lease
	r.Bindings[spaceID] = binding
	return lease, nil
}

// ScreenAllowed reports whether the holder may still drive the screen.
func (r *Registry) ScreenAllowed(botID, spaceID, leaseID string, now float64) bool {
	binding, ok := r.Bindings[spaceID]
	if !ok || binding.ScreenLease == nil {
		return false
	}
	if _, member := binding.Workspaces[botID]; !member {
		return false
	}
	if !finite(now) {
		return false
	}
	l := binding.ScreenLease
	return l.ID == leaseID && l.BotID == botID && now < l.ExpiresAt
}

// ReleaseScreen gives the lease back; a stale holder cannot release it.
func (r *Registry) ReleaseScreen(botID, spaceID, leaseID string) error {
	binding, ok := r.Bindings[spaceID]
	if !ok {
		return ErrUnknownSpace
	}
	if _, member := binding.Workspaces[botID]; !member {
		return ErrBotNotAssigned
	}
	if binding.ScreenLease == nil || binding.ScreenLease.ID != leaseID || binding.ScreenLease.BotID != botID {
		return ErrStaleLease
	}
	binding.ScreenLease = nil
	r.Bindings[spaceID] = binding
	return nil
}

// ValidWorkspace accepts an absolute path without dot segments. This is lexical
// only: the guest adapter must still refuse symlink aliases.
func ValidWorkspace(p string) (string, error) {
	if !strings.HasPrefix(p, "/") || p == "/" || strings.ContainsRune(p, 0) ||
		strings.ContainsAny(p, "\n\r") {
		return "", ErrInvalidWorkspace
	}
	for _, part := range strings.Split(p, "/")[1:] {
		if part == "" || part == "." || part == ".." {
			return "", ErrInvalidWorkspace
		}
	}
	return path.Clean(p), nil
}

// ValidAgentName matches the Volume rule: 1 to 63 of [a-z0-9._-].
func ValidAgentName(name string) bool {
	if name == "" || len(name) > 63 {
		return false
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
		default:
			return false
		}
	}
	return true
}

func normalizeGroup(group string) string {
	if strings.TrimSpace(group) == "" {
		return "default"
	}
	return strings.TrimSpace(group)
}

func finite(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0)
}

func newScreenLease(botID string, now, duration float64) ScreenLease {
	return ScreenLease{ID: NewID(), BotID: botID, ExpiresAt: now + duration}
}

// Available is the capability set a Bot credential gets: registry management is
// deliberately absent, so a Bot cannot mint tokens for another Bot.
var BotCapabilities = []Capability{
	CapSpacesRead, CapScreenControl, CapArtifactsRead, CapArtifactsWrite, CapDelegate,
}

// String renders an error with its Space and Bot for logs.
func assignmentError(botID, spaceID string, err error) error {
	return fmt.Errorf("assign %s to %s: %w", botID, spaceID, err)
}
