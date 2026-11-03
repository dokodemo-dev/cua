// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
	"time"
)

// Login codes hand a browser a credential without putting the long-lived token
// in a URL. `cua-bots-open` asks the service for a code (it already holds the
// admin token), opens /ui#c=<code>, and the page trades the code for an
// HttpOnly session cookie. A code is random, valid for a minute, and consumed
// on first use, so a value that leaks through browser history, a screenshot or
// the `ps` output of `open` is worth almost nothing.
type loginCode struct {
	token   string
	expires time.Time
}

type loginCodes struct {
	mu    sync.Mutex
	codes map[string]loginCode
	now   func() time.Time
	ttl   time.Duration
}

func newLoginCodes(now func() time.Time) *loginCodes {
	return &loginCodes{codes: map[string]loginCode{}, now: now, ttl: time.Minute}
}

// issue returns a fresh code bound to token, dropping anything expired.
func (c *loginCodes) issue(token string) (string, time.Duration) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", 0
	}
	code := base64.RawURLEncoding.EncodeToString(raw)
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	for key, entry := range c.codes {
		if !entry.expires.After(now) {
			delete(c.codes, key)
		}
	}
	c.codes[code] = loginCode{token: token, expires: now.Add(c.ttl)}
	return code, c.ttl
}

// consume returns the token for code and removes it. A code works once.
func (c *loginCodes) consume(code string) (string, bool) {
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.codes[code]
	if !ok {
		return "", false
	}
	delete(c.codes, code)
	if !entry.expires.After(now) {
		return "", false
	}
	return entry.token, true
}
