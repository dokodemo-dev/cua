// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The settings page describes the session without ever seeing the credential.
func TestSessionDescribesTheCallerWithoutTheCredential(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	rec := chatCall(t, svc, http.MethodGet, "/v1/session", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("admin session: %d %s", rec.Code, rec.Body)
	}
	if !contains(rec.Body.String(), `"role":"administrator"`) {
		t.Fatalf("role: %s", rec.Body)
	}
	if contains(rec.Body.String(), admin) {
		t.Fatal("the session must not echo the credential")
	}
	if !contains(rec.Body.String(), `"expiresAt"`) {
		t.Fatalf("no expiry: %s", rec.Body)
	}

	rec = chatCall(t, svc, http.MethodGet, "/v1/session", botCredential, "")
	if rec.Code != http.StatusOK || !contains(rec.Body.String(), `"role":"bot"`) {
		t.Fatalf("bot session: %d %s", rec.Code, rec.Body)
	}
	if rec := chatCall(t, svc, http.MethodGet, "/v1/session", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}

// Both the cookie and the fragment fallback reach this endpoint the same way.
func TestSessionWorksFromTheCookie(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	login := httptest.NewRequest(http.MethodGet, "/ui?login="+admin, nil)
	login.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, login)
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("no cookie")
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/session", nil)
	req.RemoteAddr = "127.0.0.1:50000"
	req.AddCookie(cookies[0])
	rec = httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("cookie session: %d %s", rec.Code, rec.Body)
	}
}
