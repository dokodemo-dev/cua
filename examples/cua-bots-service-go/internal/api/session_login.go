// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"time"
)

// sessionCookieName is the browser's session. It is HttpOnly, so page script
// never sees the credential; the page calls the API and the browser attaches it.
const sessionCookieName = "cua_session"

// setSessionCookie writes the session cookie. Secure is set when the request
// arrived over TLS (production); over plain HTTP the browser would drop it.
func (s *Service) setSessionCookie(w http.ResponseWriter, r *http.Request, token string, now time.Time) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   r.TLS != nil,
		SameSite: http.SameSiteStrictMode,
		Expires:  now.Add(s.sessionLifetime()),
	})
}

// clearSessionCookie removes it.
func clearSessionCookie(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name: sessionCookieName, Value: "", Path: "/",
		HttpOnly: true, Secure: r.TLS != nil, SameSite: http.SameSiteStrictMode,
		MaxAge: -1, Expires: time.Unix(0, 0),
	})
}

// securityHeaders are the defaults every UI response carries. The page needs a
// Content-Security-Policy; assets only need the sniffing and referrer guards.
func securityHeaders(w http.ResponseWriter, csp string) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
	if csp != "" {
		w.Header().Set("Content-Security-Policy", csp)
	}
}

// appCSP keeps the page to its own origin: the bundle, the stylesheet and the
// API. Inline script is not allowed, so a value that reaches the page cannot
// become script through a tag.
const appCSP = "default-src 'self'; script-src 'self'; style-src 'self'; " +
	"img-src 'self' data:; connect-src 'self'; font-src 'self'; " +
	"base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'"

// issueLoginCode answers POST /v1/login/code: a browser-ready code for the
// caller's own credential.
func (s *Service) issueLoginCode(token string) (int, any) {
	if token == "" {
		return http.StatusUnauthorized, map[string]string{"error": "missing token"}
	}
	code, ttl := s.codes.issue(token)
	if code == "" {
		return http.StatusInternalServerError, map[string]string{"error": "could not make a code"}
	}
	return http.StatusOK, map[string]any{
		"code": code, "expiresIn": int(ttl.Seconds()),
	}
}

// exchangeLogin answers POST /v1/login/exchange with either a one-time code or
// a credential (the sign-in field). Both set the HttpOnly session cookie and
// return nothing else, so the page never holds the token.
func (s *Service) exchangeLogin(w http.ResponseWriter, r *http.Request, body []byte, now time.Time) (int, any) {
	// A login attempt is cheap to brute force if it is not bounded; keep one
	// bucket per address, separate from the token buckets.
	if !s.limiter.allow("login:"+clientAddr(r), now) {
		return http.StatusTooManyRequests, map[string]string{"error": "too many attempts"}
	}
	var in struct {
		Code  string `json:"code"`
		Token string `json:"token"`
	}
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	var token string
	if code := strings.TrimSpace(in.Code); code != "" {
		consumed, ok := s.codes.consume(code)
		if !ok {
			return http.StatusUnauthorized, map[string]string{"error": "this code is no longer valid"}
		}
		token = consumed
	} else if given := strings.TrimSpace(in.Token); given != "" {
		token = given
	} else {
		return http.StatusBadRequest, map[string]string{"error": "code or token is required"}
	}
	if s.tokens.Authenticate(token, now) == nil {
		return http.StatusUnauthorized, map[string]string{"error": "invalid credential"}
	}
	s.setSessionCookie(w, r, token, now)
	w.Header().Set("Cache-Control", "no-store")
	return http.StatusNoContent, nil
}

// newNonce is the value a login page's inline script carries, so the page can
// run that one script while its policy forbids every other.
func newNonce() string {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
