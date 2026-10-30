// SPDX-License-Identifier: FSL-1.1-MIT

package domain

import (
	"crypto/rand"
	"errors"
	"time"
)

func cryptoRand(b []byte) (int, error) { return rand.Read(b) }

// Collaboration messages, tasks and artifacts. Mirrors CollaborationService.
var (
	ErrIdempotencyKeyRequired = errors.New("idempotency key required")
	ErrIdempotencyConflict    = errors.New("idempotency conflict")
	ErrParentNotFound         = errors.New("parent not found")
	ErrParentExpired          = errors.New("parent expired")
	ErrDelegationLoop         = errors.New("delegation loop")
	ErrConcurrencyLimit       = errors.New("concurrency limit")
	ErrTaskExpired            = errors.New("task expired")
	ErrTaskNotRunning         = errors.New("task not running")
	ErrInvalidArtifactName    = errors.New("invalid artifact name")
	ErrUnauthorized           = errors.New("unauthorized")
)

// MessageKind says why a message exists.
type MessageKind string

const (
	MessageNote       MessageKind = "note"
	MessageDelegation MessageKind = "delegation"
	MessageResult     MessageKind = "result"
)

// Message is one line in a Space's feed.
type Message struct {
	ID             string      `json:"id"`
	Kind           MessageKind `json:"kind"`
	IdempotencyKey string      `json:"idempotencyKey"`
	SenderBotID    string      `json:"senderBotID"`
	RecipientBotID *string     `json:"recipientBotID,omitempty"`
	SpaceID        string      `json:"spaceID"`
	Body           string      `json:"body"`
	CreatedAt      float64     `json:"createdAt"`
}

// TaskState is a delegation's life.
type TaskState string

const (
	TaskRunning   TaskState = "running"
	TaskSucceeded TaskState = "succeeded"
	TaskExpired   TaskState = "expired"
)

// DelegationTask is one bounded piece of work handed to another Bot.
type DelegationTask struct {
	ID             string    `json:"id"`
	ParentID       *string   `json:"parentID,omitempty"`
	Depth          int       `json:"depth"`
	SenderBotID    string    `json:"senderBotID"`
	RecipientBotID string    `json:"recipientBotID"`
	SpaceID        string    `json:"spaceID"`
	Deadline       float64   `json:"deadline"`
	Path           []string  `json:"path"`
	State          TaskState `json:"state"`
	Result         *string   `json:"result,omitempty"`
}

// Artifact is a reference; the bytes stay in the Bot's own directory.
type Artifact struct {
	ID         string  `json:"id"`
	OwnerBotID string  `json:"ownerBotID"`
	SpaceID    string  `json:"spaceID"`
	Name       string  `json:"name"`
	ByteCount  int64   `json:"byteCount"`
	Sha256     string  `json:"sha256"`
	CreatedAt  float64 `json:"createdAt"`
}

type storedTask struct {
	Task        DelegationTask `json:"task"`
	Prompt      string         `json:"prompt"`
	Fingerprint string         `json:"fingerprint"`
}

// CollaborationSnapshot is what a state file keeps.
type CollaborationSnapshot struct {
	Stored    map[string]storedTask `json:"stored"`
	ByKey     map[string]string     `json:"byKey"`
	Messages  []Message             `json:"messages"`
	Artifacts []Artifact            `json:"artifacts"`
}

// Collaboration is the in-memory collaboration state.
type Collaboration struct {
	Registry Registry
	State    CollaborationSnapshot
}

// NewCollaboration returns empty collaboration state bound to a registry.
func NewCollaboration(r Registry) *Collaboration {
	return &Collaboration{Registry: r, State: CollaborationSnapshot{
		Stored: map[string]storedTask{}, ByKey: map[string]string{},
		Messages: []Message{}, Artifacts: []Artifact{},
	}}
}

// MaxGlobalConcurrency and MaxPerBotConcurrency bound running delegations.
const (
	MaxGlobalConcurrency = 4
	MaxPerBotConcurrency = 1
)

// DelegateResult is what the API returns.
type DelegateResult struct {
	Task  DelegationTask
	Fresh bool
}

// Delegate hands one prompt to another Bot, with the same guarantees as Swift:
// idempotent by key, loop-free along the root path, depth and concurrency
// bounded, and a deadline that never outlives its parent.
func (c *Collaboration) Delegate(
	p Principal, recipient, spaceID, prompt, idempotencyKey string, parentID *string,
	now time.Time, deadline time.Time,
) (DelegateResult, error) {
	if idempotencyKey == "" {
		return DelegateResult{}, ErrIdempotencyKeyRequired
	}
	fingerprint := recipient + "\x01" + spaceID + "\x01" + prompt
	if existingID, ok := c.State.ByKey[idempotencyKey]; ok {
		record, ok := c.State.Stored[existingID]
		if !ok || record.Fingerprint != fingerprint {
			return DelegateResult{}, ErrIdempotencyConflict
		}
		return DelegateResult{Task: record.Task, Fresh: false}, nil
	}
	path := []string{p.BotID}
	depth := 1
	effective := deadline
	if parentID != nil {
		record, ok := c.State.Stored[*parentID]
		if !ok {
			return DelegateResult{}, ErrParentNotFound
		}
		parent := record.Task
		if parent.State == TaskExpired {
			return DelegateResult{}, ErrParentExpired
		}
		if parent.State != TaskRunning {
			return DelegateResult{}, ErrTaskNotRunning
		}
		path = append([]string{}, parent.Path...)
		depth = parent.Depth + 1
		if parentDeadline := unixToTime(parent.Deadline); parentDeadline.Before(effective) {
			effective = parentDeadline
		}
	}
	for _, seen := range path {
		if seen == recipient {
			return DelegateResult{}, ErrDelegationLoop
		}
	}
	if depth > 3 {
		return DelegateResult{}, ErrDepthExceeded
	}
	if err := CanDelegate(p, p.TrustGroup, depth, effective, now); err != nil {
		return DelegateResult{}, err
	}
	// The recipient must be in the caller's Space and trust group.
	binding, ok := c.Registry.Bindings[spaceID]
	if !ok || binding.Group() != normalizeGroup(p.TrustGroup) {
		return DelegateResult{}, ErrUnauthorized
	}
	if _, ok := binding.Workspaces[p.BotID]; !ok {
		return DelegateResult{}, ErrUnauthorized
	}
	if _, ok := binding.Workspaces[recipient]; !ok {
		return DelegateResult{}, ErrUnauthorized
	}
	if !now.Before(effective) {
		return DelegateResult{}, ErrTaskExpired
	}
	if c.runningCount() >= MaxGlobalConcurrency || c.runningFor(recipient) >= MaxPerBotConcurrency {
		return DelegateResult{}, ErrConcurrencyLimit
	}
	task := DelegationTask{
		ID:             NewID(),
		ParentID:       parentID,
		Depth:          depth,
		SenderBotID:    p.BotID,
		RecipientBotID: recipient,
		SpaceID:        spaceID,
		Deadline:       float64(effective.Unix()),
		Path:           append(path, recipient),
		State:          TaskRunning,
	}
	c.State.Stored[task.ID] = storedTask{Task: task, Prompt: prompt, Fingerprint: fingerprint}
	c.State.ByKey[idempotencyKey] = task.ID
	c.State.Messages = append(c.State.Messages, Message{
		ID: NewID(), Kind: MessageDelegation, IdempotencyKey: idempotencyKey,
		SenderBotID: p.BotID, RecipientBotID: &recipient, SpaceID: spaceID, Body: prompt,
		CreatedAt: float64(now.Unix()),
	})
	return DelegateResult{Task: task, Fresh: true}, nil
}

// Complete records a result; a late result is refused.
func (c *Collaboration) Complete(taskID, result string, now time.Time) error {
	record, ok := c.State.Stored[taskID]
	if !ok {
		return ErrTaskNotRunning
	}
	task := record.Task
	if task.State != TaskRunning {
		if task.State == TaskExpired {
			return ErrTaskExpired
		}
		return ErrTaskNotRunning
	}
	if !now.Before(unixToTime(task.Deadline)) {
		task.State = TaskExpired
		record.Task = task
		c.State.Stored[taskID] = record
		return ErrTaskExpired
	}
	task.State = TaskSucceeded
	task.Result = &result
	record.Task = task
	c.State.Stored[taskID] = record
	sender := task.SenderBotID
	c.State.Messages = append(c.State.Messages, Message{
		ID: NewID(), Kind: MessageResult, IdempotencyKey: "result-" + taskID,
		SenderBotID: task.RecipientBotID, RecipientBotID: &sender, SpaceID: task.SpaceID,
		Body: result, CreatedAt: float64(now.Unix()),
	})
	return nil
}

// Expire turns every overdue running task into expired.
func (c *Collaboration) Expire(now time.Time) {
	for id, record := range c.State.Stored {
		if record.Task.State != TaskRunning {
			continue
		}
		if now.Before(unixToTime(record.Task.Deadline)) {
			continue
		}
		record.Task.State = TaskExpired
		c.State.Stored[id] = record
	}
}

// Post writes a note to a Space, to everyone or to one recipient.
func (c *Collaboration) Post(
	p Principal, spaceID, body string, recipient *string, idempotencyKey string, now time.Time,
) (Message, error) {
	if idempotencyKey == "" {
		return Message{}, ErrIdempotencyKeyRequired
	}
	binding, ok := c.Registry.Bindings[spaceID]
	if !ok || p.SpaceID != spaceID || binding.Group() != normalizeGroup(p.TrustGroup) {
		return Message{}, ErrNotAMember
	}
	if _, ok := binding.Workspaces[p.BotID]; !ok {
		return Message{}, ErrNotAMember
	}
	if recipient != nil {
		if _, ok := binding.Workspaces[*recipient]; !ok {
			return Message{}, ErrNotAMember
		}
	}
	for _, m := range c.State.Messages {
		if m.IdempotencyKey == idempotencyKey {
			return m, nil
		}
	}
	message := Message{
		ID: NewID(), Kind: MessageNote, IdempotencyKey: idempotencyKey,
		SenderBotID: p.BotID, RecipientBotID: recipient, SpaceID: spaceID, Body: body,
		CreatedAt: float64(now.Unix()),
	}
	c.State.Messages = append(c.State.Messages, message)
	return message, nil
}

// Deliverable lists messages for a Bot: its own, or its Space's, never its own
// writing, and only while it is a member.
func (c *Collaboration) Deliverable(botID string, now time.Time) []Message {
	spaces := map[string]bool{}
	for _, b := range c.Registry.Bindings {
		if _, ok := b.Workspaces[botID]; ok {
			spaces[b.SpaceID] = true
		}
	}
	out := []Message{}
	for _, m := range c.State.Messages {
		if m.SenderBotID == botID || !spaces[m.SpaceID] {
			continue
		}
		if m.CreatedAt > float64(now.Unix()) {
			continue
		}
		if m.RecipientBotID != nil && *m.RecipientBotID != botID {
			continue
		}
		out = append(out, m)
	}
	return out
}

// RegisterArtifact records a produced file, owned by the caller.
func (c *Collaboration) RegisterArtifact(
	p Principal, spaceID, name string, byteCount int64, sha string, now time.Time,
) (Artifact, error) {
	if !p.Has(CapArtifactsWrite) {
		return Artifact{}, ErrMissingCapability
	}
	if err := memberOf(c.Registry, p, spaceID); err != nil {
		return Artifact{}, err
	}
	if byteCount < 0 || byteCount > 8*1024*1024 {
		return Artifact{}, ErrArtifactTooLarge
	}
	if name == "" || name != pathBase(name) || len(name) > 255 {
		return Artifact{}, ErrInvalidArtifactName
	}
	artifact := Artifact{
		ID: NewID(), OwnerBotID: p.BotID, SpaceID: spaceID, Name: name,
		ByteCount: byteCount, Sha256: sha, CreatedAt: float64(now.Unix()),
	}
	c.State.Artifacts = append(c.State.Artifacts, artifact)
	return artifact, nil
}

// Artifacts lists the artifacts visible to a Bot (its Spaces).
func (c *Collaboration) Artifacts(botID string) []Artifact {
	spaces := map[string]bool{}
	for _, b := range c.Registry.Bindings {
		if _, ok := b.Workspaces[botID]; ok {
			spaces[b.SpaceID] = true
		}
	}
	out := []Artifact{}
	for _, a := range c.State.Artifacts {
		if spaces[a.SpaceID] {
			out = append(out, a)
		}
	}
	return out
}

func (c *Collaboration) runningCount() int {
	n := 0
	for _, record := range c.State.Stored {
		if record.Task.State == TaskRunning {
			n++
		}
	}
	return n
}

func (c *Collaboration) runningFor(botID string) int {
	n := 0
	for _, record := range c.State.Stored {
		if record.Task.State == TaskRunning && record.Task.RecipientBotID == botID {
			n++
		}
	}
	return n
}

func unixToTime(v float64) time.Time {
	sec := int64(v)
	nsec := int64((v - float64(sec)) * 1e9)
	return time.Unix(sec, nsec)
}

// pathBase is filepath.Base without importing path/filepath's OS rules.
func pathBase(name string) string {
	for i := len(name) - 1; i >= 0; i-- {
		if name[i] == '/' || name[i] == '\\' {
			return name[i+1:]
		}
	}
	return name
}
