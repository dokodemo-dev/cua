// SPDX-License-Identifier: FSL-1.1-MIT

package domain

import (
	"errors"
	"time"
)

// Scheduler errors.
var (
	ErrInvalidCadence  = errors.New("invalid cadence")
	ErrUnknownJob      = errors.New("unknown job")
	ErrUnknownDelivery = errors.New("unknown delivery")
	ErrInvalidState    = errors.New("invalid transition")
	ErrLeaseLost       = errors.New("lease lost")
	ErrLeaseHeld       = errors.New("lease held by another owner")
)

// DeliveryState is one scheduled slot's life.
type DeliveryState string

const (
	DeliveryClaimed     DeliveryState = "claimed"
	DeliveryPending     DeliveryState = "pending"
	DeliveryDelivered   DeliveryState = "delivered"
	DeliveryFailed      DeliveryState = "failed"
	DeliveryUnconfirmed DeliveryState = "unconfirmed"
)

// Job is one schedule: a prompt for a Bot, every Cadence seconds.
type Job struct {
	ID        string  `json:"id"`
	BotID     string  `json:"botID"`
	Title     string  `json:"title"`
	Prompt    string  `json:"prompt"`
	Cadence   float64 `json:"cadence"`
	NextRunAt float64 `json:"nextRunAt"`
	Paused    bool    `json:"isPaused"`
	// PausedByArchive marks a pause that came from archiving the Bot, so
	// restoring it resumes exactly those and leaves a hand-paused one alone.
	PausedByArchive bool `json:"pausedByArchive,omitempty"`
}

// Delivery is one slot of a job, keyed by job and scheduled time.
type Delivery struct {
	Key         string        `json:"key"`
	JobID       string        `json:"jobID"`
	ScheduledAt float64       `json:"scheduledAt"`
	State       DeliveryState `json:"state"`
	Attempts    int           `json:"attempts"`
	ClaimedAt   float64       `json:"claimedAt"`
	UpdatedAt   float64       `json:"updatedAt"`
}

// Lease is the single writer's claim on the schedule.
type Lease struct {
	Owner      string  `json:"owner"`
	ExpiresAt  float64 `json:"expiresAt"`
	Generation int     `json:"generation"`
}

// Claim is what a runner is allowed to execute.
type Claim struct {
	JobID       string
	BotID       string
	Title       string
	Prompt      string
	ScheduledAt time.Time
	Key         string
	Attempt     int
}

// Scheduler holds the schedule. One lease holder claims slots, so a second
// process (or a restarted one) never delivers the same slot twice.
type Scheduler struct {
	OwnerID      string              `json:"ownerID"`
	ClaimTimeout float64             `json:"claimTimeout"`
	Jobs         map[string]Job      `json:"jobs"`
	Deliveries   map[string]Delivery `json:"deliveries"`
	Lease        *Lease              `json:"lease,omitempty"`
}

// NewScheduler returns an empty schedule owned by owner.
func NewScheduler(owner string) *Scheduler {
	return &Scheduler{
		OwnerID: owner, ClaimTimeout: 120,
		Jobs: map[string]Job{}, Deliveries: map[string]Delivery{},
	}
}

// AddJob registers a schedule and returns its id.
func (s *Scheduler) AddJob(botID, title, prompt string, cadence float64, start time.Time) (string, error) {
	if cadence < 1 {
		return "", ErrInvalidCadence
	}
	job := Job{
		ID: NewID(), BotID: botID, Title: title, Prompt: prompt,
		Cadence: cadence, NextRunAt: float64(start.Unix()),
	}
	s.Jobs[job.ID] = job
	return job.ID, nil
}

// SetPausedForArchive stops every routine of a Bot, remembering which ones this
// pause is responsible for. A routine the operator had already stopped stays
// stopped after the Bot is restored.
func (s *Scheduler) SetPausedForArchive(botID string, paused bool) int {
	changed := 0
	for id, job := range s.Jobs {
		if job.BotID != botID {
			continue
		}
		if paused {
			if job.Paused {
				continue
			}
			job.Paused = true
			job.PausedByArchive = true
		} else {
			if !job.PausedByArchive {
				continue
			}
			job.Paused = false
			job.PausedByArchive = false
		}
		s.Jobs[id] = job
		changed++
	}
	return changed
}

// SetPaused stops or resumes a job.
func (s *Scheduler) SetPaused(id string, paused bool) {
	job, ok := s.Jobs[id]
	if !ok {
		return
	}
	// A decision made by hand always wins over the archive's own pause.
	job.Paused = paused
	job.PausedByArchive = false
	s.Jobs[id] = job
}

// AcquireLease takes or renews the lease. Taking over from another owner turns
// its in-flight claims into unconfirmed: nobody resends blindly.
func (s *Scheduler) AcquireLease(now time.Time, duration time.Duration) error {
	if duration <= 0 {
		return ErrInvalidState
	}
	n := float64(now.Unix())
	if s.Lease != nil && s.Lease.Owner != s.OwnerID && s.Lease.ExpiresAt > n {
		return ErrLeaseHeld
	}
	takeover := s.Lease == nil || s.Lease.Owner != s.OwnerID
	generation := 1
	if !takeover && s.Lease != nil {
		generation = s.Lease.Generation
	} else if s.Lease != nil {
		generation = s.Lease.Generation + 1
	}
	s.Lease = &Lease{Owner: s.OwnerID, ExpiresAt: n + duration.Seconds(), Generation: generation}
	if takeover {
		for key, delivery := range s.Deliveries {
			if delivery.State != DeliveryClaimed {
				continue
			}
			delivery.State = DeliveryUnconfirmed
			delivery.UpdatedAt = n
			s.Deliveries[key] = delivery
		}
	}
	return nil
}

// HasLease reports whether this owner holds a live lease.
func (s *Scheduler) HasLease(now time.Time) bool {
	return s.Lease != nil && s.Lease.Owner == s.OwnerID && float64(now.Unix()) < s.Lease.ExpiresAt
}

// ClaimDue claims up to limit due slots. Slots a human asked to resend are
// claimable even though their job has moved on.
func (s *Scheduler) ClaimDue(now time.Time, limit int) ([]Claim, error) {
	if !s.HasLease(now) {
		return nil, ErrLeaseLost
	}
	n := float64(now.Unix())
	claims := []Claim{}
	seen := map[string]bool{}

	ids := make([]string, 0, len(s.Jobs))
	for id := range s.Jobs {
		ids = append(ids, id)
	}
	sortStrings(ids)
	for _, id := range ids {
		job := s.Jobs[id]
		if job.Paused || job.NextRunAt > n {
			continue
		}
		if len(claims) >= limit {
			break
		}
		key := DeliveryKey(job.ID, unixToTime(job.NextRunAt))
		delivery, ok := s.Deliveries[key]
		if !ok {
			delivery = Delivery{Key: key, JobID: job.ID, ScheduledAt: job.NextRunAt, State: DeliveryClaimed}
		}
		if delivery.State != DeliveryClaimed && delivery.State != DeliveryPending {
			// The slot already ran (or was acknowledged): move the job on.
			job.NextRunAt += job.Cadence
			s.Jobs[id] = job
			continue
		}
		delivery.Attempts++
		delivery.State = DeliveryClaimed
		delivery.ClaimedAt = n
		delivery.UpdatedAt = n
		s.Deliveries[key] = delivery
		job.NextRunAt += job.Cadence
		s.Jobs[id] = job
		seen[key] = true
		claims = append(claims, Claim{
			JobID: job.ID, BotID: job.BotID, Title: job.Title, Prompt: job.Prompt,
			ScheduledAt: unixToTime(delivery.ScheduledAt), Key: key, Attempt: delivery.Attempts,
		})
	}

	keys := make([]string, 0, len(s.Deliveries))
	for key := range s.Deliveries {
		keys = append(keys, key)
	}
	sortStrings(keys)
	for _, key := range keys {
		delivery := s.Deliveries[key]
		if delivery.State != DeliveryPending || seen[key] || len(claims) >= limit {
			continue
		}
		job, ok := s.Jobs[delivery.JobID]
		if !ok {
			continue
		}
		delivery.Attempts++
		delivery.State = DeliveryClaimed
		delivery.ClaimedAt = n
		delivery.UpdatedAt = n
		s.Deliveries[key] = delivery
		claims = append(claims, Claim{
			JobID: job.ID, BotID: job.BotID, Title: job.Title, Prompt: job.Prompt,
			ScheduledAt: unixToTime(delivery.ScheduledAt), Key: key, Attempt: delivery.Attempts,
		})
	}
	return claims, nil
}

// MarkDelivered records a finished slot.
func (s *Scheduler) MarkDelivered(key string, now time.Time) error {
	if !s.HasLease(now) {
		return ErrLeaseLost
	}
	delivery, ok := s.Deliveries[key]
	if !ok {
		return ErrUnknownDelivery
	}
	if delivery.State != DeliveryClaimed {
		return ErrInvalidState
	}
	delivery.State = DeliveryDelivered
	delivery.UpdatedAt = float64(now.Unix())
	s.Deliveries[key] = delivery
	return nil
}

// MarkFailed records a slot that did not complete; nothing retries it.
func (s *Scheduler) MarkFailed(key string, now time.Time) error {
	if !s.HasLease(now) {
		return ErrLeaseLost
	}
	delivery, ok := s.Deliveries[key]
	if !ok {
		return ErrUnknownDelivery
	}
	if delivery.State != DeliveryClaimed {
		return ErrInvalidState
	}
	delivery.State = DeliveryFailed
	delivery.UpdatedAt = float64(now.Unix())
	s.Deliveries[key] = delivery
	return nil
}

// ReclaimExpired turns claims whose outcome is unknown into unconfirmed.
func (s *Scheduler) ReclaimExpired(now time.Time) {
	n := float64(now.Unix())
	for key, delivery := range s.Deliveries {
		if delivery.State != DeliveryClaimed {
			continue
		}
		if n < delivery.ClaimedAt+s.ClaimTimeout {
			continue
		}
		delivery.State = DeliveryUnconfirmed
		delivery.UpdatedAt = n
		s.Deliveries[key] = delivery
	}
}

// Unresolved lists slots nobody may resend until a human decides.
func (s *Scheduler) Unresolved() []Delivery {
	out := []Delivery{}
	for _, delivery := range s.Deliveries {
		if delivery.State == DeliveryClaimed || delivery.State == DeliveryUnconfirmed {
			out = append(out, delivery)
		}
	}
	return out
}

// Acknowledge is the explicit human decision: resend once, or give up.
func (s *Scheduler) Acknowledge(key string, resend bool, now time.Time) error {
	delivery, ok := s.Deliveries[key]
	if !ok {
		return ErrUnknownDelivery
	}
	if delivery.State != DeliveryUnconfirmed && delivery.State != DeliveryClaimed &&
		delivery.State != DeliveryFailed {
		return ErrInvalidState
	}
	if resend {
		delivery.State = DeliveryPending
	} else {
		delivery.State = DeliveryFailed
	}
	delivery.UpdatedAt = float64(now.Unix())
	s.Deliveries[key] = delivery
	return nil
}

// DeliveryKey is the slot identity: job plus the scheduled instant (UTC).
func DeliveryKey(jobID string, scheduledAt time.Time) string {
	return jobID + "@" + scheduledAt.UTC().Format("2006-01-02T15:04:05Z")
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}

// RemoveJob unregisters a schedule and drops its queued slots, so a removed
// routine cannot be delivered by a claim that was already in flight.
func (s *Scheduler) RemoveJob(id string) error {
	if _, ok := s.Jobs[id]; !ok {
		return ErrUnknownJob
	}
	delete(s.Jobs, id)
	for key, delivery := range s.Deliveries {
		if delivery.JobID == id {
			delete(s.Deliveries, key)
		}
	}
	return nil
}
