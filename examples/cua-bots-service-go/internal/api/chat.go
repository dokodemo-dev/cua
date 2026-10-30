// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"errors"
	"sync"
	"time"
)

// Chat errors.
var (
	ErrChatBusy    = errors.New("a turn is already running for this bot")
	ErrEmptyPrompt = errors.New("prompt is empty")
)

// Turn is one chat turn: the prompt a person sent and what the harness printed.
type Turn struct {
	ID        string  `json:"id"`
	Prompt    string  `json:"prompt"`
	Output    string  `json:"output"`
	Status    string  `json:"status"` // StatusRunning | StatusDone | StatusFailed
	Error     string  `json:"error,omitempty"`
	StartedAt float64 `json:"startedAt"`
	EndedAt   float64 `json:"endedAt,omitempty"`
}

// maxOutput bounds what one turn may hold (bytes); the browser polls, so the
// newest tail is what matters.
const maxOutput = 64 << 10

// TurnRunner runs one turn for a bot, calling write with each chunk of output.
type TurnRunner func(turnID, botID, prompt string, write func(string)) error

// Chat keeps the recent turns of each Bot. The Space keeps the conversation;
// this is the window the browser reads, persisted so a restart does not clear
// the page.
type Chat struct {
	mu       sync.Mutex
	turns    map[string][]Turn
	running  map[string]bool
	seq      int
	runner   TurnRunner
	now      func() time.Time
	keep     int
	onFinish func()
}

// NewChat builds an empty chat window over the given runner.
func NewChat(runner TurnRunner, now func() time.Time) *Chat {
	if now == nil {
		now = time.Now
	}
	return &Chat{turns: map[string][]Turn{}, running: map[string]bool{},
		runner: runner, now: now, keep: 200}
}

// Restore loads turns saved by a previous process. A turn that was running when
// the service stopped is reported as failed: its output is gone with it.
func (c *Chat) Restore(saved map[string][]Turn) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for botID, turns := range saved {
		restored := make([]Turn, 0, len(turns))
		for _, t := range turns {
			if t.Status == "running" {
				t.Status = "failed"
				t.Error = "interrupted by a service restart"
			}
			restored = append(restored, t)
			c.seq++
		}
		c.turns[botID] = restored
	}
}

// Snapshot returns the turns to persist.
func (c *Chat) Snapshot() map[string][]Turn {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string][]Turn, len(c.turns))
	for botID, turns := range c.turns {
		if len(turns) == 0 {
			continue
		}
		cp := make([]Turn, len(turns))
		copy(cp, turns)
		out[botID] = cp
	}
	return out
}

// SetOnFinish installs the hook that persists a finished turn.
func (c *Chat) SetOnFinish(f func()) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.onFinish = f
}

// Start records a running turn and runs it in the background.
func (c *Chat) Start(botID, prompt string) (Turn, error) {
	if prompt == "" {
		return Turn{}, ErrEmptyPrompt
	}
	c.mu.Lock()
	if c.running[botID] {
		c.mu.Unlock()
		return Turn{}, ErrChatBusy
	}
	c.seq++
	turn := Turn{
		ID:        "turn-" + itoa(c.seq),
		Prompt:    prompt,
		Status:    "running",
		StartedAt: float64(c.now().Unix()),
	}
	c.running[botID] = true
	c.turns[botID] = append(c.turns[botID], turn)
	index := len(c.turns[botID]) - 1
	c.mu.Unlock()

	go func() {
		err := c.runner(turn.ID, botID, prompt, func(chunk string) {
			c.append(botID, index, chunk)
		})
		c.finish(botID, index, err)
	}()
	return turn, nil
}

func (c *Chat) append(botID string, index int, chunk string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	turns := c.turns[botID]
	if index >= len(turns) {
		return
	}
	out := turns[index].Output + chunk
	if len(out) > maxOutput {
		out = out[len(out)-maxOutput:]
	}
	turns[index].Output = out
}

func (c *Chat) finish(botID string, index int, err error) {
	c.mu.Lock()
	turns := c.turns[botID]
	if index >= len(turns) {
		c.mu.Unlock()
		return
	}
	if err != nil {
		turns[index].Status = "failed"
		turns[index].Error = err.Error()
	} else {
		turns[index].Status = "done"
	}
	turns[index].EndedAt = float64(c.now().Unix())
	c.running[botID] = false
	if len(turns) > c.keep {
		c.turns[botID] = turns[len(turns)-c.keep:]
	}
	hook := c.onFinish
	c.mu.Unlock()
	if hook != nil {
		hook()
	}
}

// Record adds a turn that ran elsewhere (the scheduler's routine) to the same
// window, so the browser shows every turn of the Bot in one place.
func (c *Chat) Record(botID, prompt, output, status string) Turn {
	if status != "failed" && status != "done" {
		status = "done"
	}
	c.mu.Lock()
	if c.running[botID] {
		c.mu.Unlock()
		return Turn{}
	}
	c.seq++
	now := float64(c.now().Unix())
	turn := Turn{ID: "turn-" + itoa(c.seq), Prompt: prompt, Output: output,
		Status: status, StartedAt: now, EndedAt: now}
	c.turns[botID] = append(c.turns[botID], turn)
	if len(c.turns[botID]) > c.keep {
		c.turns[botID] = c.turns[botID][len(c.turns[botID])-c.keep:]
	}
	c.mu.Unlock()
	// No onFinish here: the caller holds the service lock, and the request
	// itself is persisted once the handler returns.
	return turn
}

// LastActive is when a Bot last started a turn: the newest turn it still holds,
// or zero when it has had none. The rail sorts "最後に動いた順" by it.
func (c *Chat) LastActive(botID string) float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	turns := c.turns[botID]
	if len(turns) == 0 {
		return 0
	}
	newest := 0.0
	for _, turn := range turns {
		if turn.StartedAt > newest {
			newest = turn.StartedAt
		}
	}
	return newest
}

// List returns the turns after index, and the index to ask from next time.
func (c *Chat) List(botID string, after int) ([]Turn, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	turns := c.turns[botID]
	if after < 0 || after > len(turns) {
		after = len(turns)
	}
	out := make([]Turn, 0, len(turns)-after)
	// Turns at or after the cursor, plus anything still running: a turn's text
	// grows while it runs, and the cursor has already moved past it.
	// The newest turns are always sent, so a turn that finishes after the
	// cursor has moved past it still reaches the window that is showing it.
	fresh := len(turns) - 2
	for i, turn := range turns {
		if i >= after || i >= fresh || turn.Status == StatusRunning {
			out = append(out, turn)
		}
	}
	return out, len(turns)
}

// The turn's state, as the browser reads it.
const (
	StatusRunning = "running"
	StatusDone    = "done"
	StatusFailed  = "failed"
)

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
