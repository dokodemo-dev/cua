// SPDX-License-Identifier: FSL-1.1-MIT

package domain

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
	"time"
)

// Capability is one thing a credential may do.
type Capability string

const (
	CapSpacesRead     Capability = "spacesRead"
	CapScreenControl  Capability = "screenControl"
	CapArtifactsRead  Capability = "artifactsRead"
	CapArtifactsWrite Capability = "artifactsWrite"
	CapDelegate       Capability = "delegate"
	CapManageRegistry Capability = "manageRegistry"
)

// Principal is who a request runs as, derived from a token, never from input.
type Principal struct {
	BotID        string
	TrustGroup   string
	SpaceID      string
	Capabilities map[Capability]bool
}

// Has reports a capability.
func (p Principal) Has(c Capability) bool { return p.Capabilities[c] }

// TokenRecord is what the store keeps: no bearer value, only its digest.
type TokenRecord struct {
	BotID        string       `json:"botID"`
	TrustGroup   string       `json:"trustGroup"`
	SpaceID      *string      `json:"spaceID"`
	Capabilities []Capability `json:"capabilities"`
	ExpiresAt    float64      `json:"expiresAt"`
}

// TokenEntry is one issued credential.
type TokenEntry struct {
	Record    TokenRecord `json:"record"`
	RevokedAt *float64    `json:"revokedAt,omitempty"`
}

// TokenStore keeps digests, so a leaked state file cannot be replayed.
type TokenStore struct {
	Entries map[string]TokenEntry `json:"entries"`
}

// NewTokenStore returns an empty store.
func NewTokenStore() TokenStore { return TokenStore{Entries: map[string]TokenEntry{}} }

// Issue mints a token for one Bot and returns the bearer value exactly once.
func (s *TokenStore) Issue(botID, trustGroup string, spaceID *string, caps []Capability,
	now time.Time, lifetime time.Duration) (string, error) {
	if s.Entries == nil {
		s.Entries = map[string]TokenEntry{}
	}
	if lifetime <= 0 {
		return "", errors.New("invalid lifetime")
	}
	raw := make([]byte, 32)
	if _, err := cryptoRand(raw); err != nil {
		return "", err
	}
	value := base64.RawURLEncoding.EncodeToString(raw)
	s.Entries[Digest(value)] = TokenEntry{Record: TokenRecord{
		BotID:        botID,
		TrustGroup:   trustGroup,
		SpaceID:      spaceID,
		Capabilities: caps,
		ExpiresAt:    float64(now.Unix()) + lifetime.Seconds(),
	}}
	return value, nil
}

// Revoke invalidates one token.
func (s *TokenStore) Revoke(token string, now time.Time) {
	key := Digest(token)
	entry, ok := s.Entries[key]
	if !ok {
		return
	}
	at := float64(now.Unix())
	entry.RevokedAt = &at
	s.Entries[key] = entry
}

// RevokeAll invalidates every live token of one Bot (rotation).
func (s *TokenStore) RevokeAll(botID string, now time.Time) {
	at := float64(now.Unix())
	for key, entry := range s.Entries {
		if entry.Record.BotID != botID || entry.RevokedAt != nil {
			continue
		}
		entry.RevokedAt = &at
		s.Entries[key] = entry
	}
}

// Authenticate resolves a bearer value to a principal, or nil.
func (s *TokenStore) Authenticate(token string, now time.Time) *Principal {
	entry, ok := s.Entries[Digest(token)]
	if !ok || entry.RevokedAt != nil || float64(now.Unix()) >= entry.Record.ExpiresAt {
		return nil
	}
	rec := entry.Record
	caps := make(map[Capability]bool, len(rec.Capabilities))
	for _, c := range rec.Capabilities {
		caps[c] = true
	}
	p := Principal{BotID: rec.BotID, TrustGroup: rec.TrustGroup, Capabilities: caps}
	if rec.SpaceID != nil {
		p.SpaceID = *rec.SpaceID
	}
	return &p
}

// Expiry reports when a credential stops working, or the zero time when it is
// unknown or revoked. It never reveals the value.
func (s *TokenStore) Expiry(token string) time.Time {
	entry, ok := s.Entries[Digest(token)]
	if !ok || entry.RevokedAt != nil {
		return time.Time{}
	}
	return time.Unix(int64(entry.Record.ExpiresAt), 0)
}

// Digest is FNV-1a 64 in hex, the same function the Swift build used, so a state
// file written by either side keeps its tokens working.
func Digest(token string) string {
	var hash uint64 = 0xcbf29ce484222325
	for i := 0; i < len(token); i++ {
		hash ^= uint64(token[i])
		hash *= 0x100000001b3
	}
	return hex.EncodeToString([]byte{
		byte(hash >> 56), byte(hash >> 48), byte(hash >> 40), byte(hash >> 32),
		byte(hash >> 24), byte(hash >> 16), byte(hash >> 8), byte(hash),
	})
}

// NewID returns a random identifier (a UUID-shaped hex string).
func NewID() string {
	raw := make([]byte, 16)
	if _, err := cryptoRand(raw); err != nil {
		return ""
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	h := hex.EncodeToString(raw)
	return strings.Join([]string{h[0:8], h[8:12], h[12:16], h[16:20], h[20:32]}, "-")
}

// CanDelegate applies the delegation limits: explicit recipient in the caller's
// trust group, depth at most three, deadline at most thirty minutes.
func CanDelegate(p Principal, recipientGroup string, depth int, deadline, now time.Time) error {
	if !p.Has(CapDelegate) {
		return ErrMissingCapability
	}
	if recipientGroup != p.TrustGroup {
		return ErrCrossTrustGroup
	}
	if depth < 1 || depth > 3 {
		return ErrDepthExceeded
	}
	if deadline.Sub(now) > 30*time.Minute {
		return ErrDeadlineTooLong
	}
	return nil
}

// Authorization errors.
var (
	ErrMissingCapability = errors.New("missing capability")
	ErrNotAMember        = errors.New("not a member")
	ErrCrossBotAccess    = errors.New("cross bot access")
	ErrArtifactTooLarge  = errors.New("artifact too large")
	ErrCrossTrustGroup   = errors.New("cross trust group")
	ErrSelfDelegation    = errors.New("self delegation")
	ErrDepthExceeded     = errors.New("delegation depth exceeded")
	ErrDeadlineTooLong   = errors.New("deadline too long")
	ErrScreenLeaseNeeded = errors.New("screen lease required")
	ErrNotLocal          = errors.New("management is local only")
)

// Authorize reads a Space as a member of its trust group.
func Authorize(r Registry, p Principal, spaceID string) error {
	if !p.Has(CapSpacesRead) {
		return ErrMissingCapability
	}
	return memberOf(r, p, spaceID)
}

func memberOf(r Registry, p Principal, spaceID string) error {
	b, ok := r.Bindings[spaceID]
	if !ok || p.SpaceID != spaceID || b.Group() != normalizeGroup(p.TrustGroup) {
		return ErrNotAMember
	}
	if _, ok := b.Workspaces[p.BotID]; !ok {
		return ErrNotAMember
	}
	return nil
}

// sortedKeys is a small helper for deterministic output in errors and tests.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// EqualToken digests in constant time, for tests and diagnostics.
func EqualToken(a, b string) bool {
	return hmac.Equal([]byte(Digest(a)), []byte(Digest(b)))
}

// Sha256Hex is the artifact digest form the API accepts.
func Sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
