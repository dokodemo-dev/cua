// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Every browser request goes through the session cookie, so the endpoints that
// need an administrator have to read the cookie too. Missing this made
// "create a Bot" answer 403 while the very same page listed Bots fine.
func TestCreatingABotWorksFromTheSessionCookie(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	login := httptest.NewRequest(http.MethodGet, "/ui?login="+admin, nil)
	login.RemoteAddr = "127.0.0.1:50000"
	rec := httptest.NewRecorder()
	svc.ServeHTTP(rec, login)
	cookies := rec.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("no session cookie")
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/manage/bots",
		strings.NewReader(`{"botID":"gamma","spaceID":"local:bot-gamma"}`))
	req.RemoteAddr = "127.0.0.1:50000"
	req.AddCookie(cookies[0])
	rec = httptest.NewRecorder()
	svc.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("cookie create: %d %s", rec.Code, rec.Body)
	}
}
