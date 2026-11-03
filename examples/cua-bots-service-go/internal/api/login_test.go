// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

// A code signs a browser in once: the exchange sets the cookie and the code is
// gone afterwards.
func TestALoginCodeWorksOnceAndSetsTheCookie(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	rec := chatCall(t, svc, http.MethodPost, "/v1/login/code", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("code: %d %s", rec.Code, rec.Body)
	}
	var issued struct {
		Code      string `json:"code"`
		ExpiresIn int    `json:"expiresIn"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &issued); err != nil {
		t.Fatal(err)
	}
	if issued.Code == "" || issued.ExpiresIn <= 0 {
		t.Fatalf("issued: %+v", issued)
	}

	exchange := func(code string) *http.Response {
		body := `{"code":"` + code + `"}`
		call := chatCall(t, svc, http.MethodPost, "/v1/login/exchange", "", body)
		return call.Result()
	}
	first := exchange(issued.Code)
	if first.StatusCode != http.StatusNoContent {
		t.Fatalf("exchange: %d", first.StatusCode)
	}
	cookies := first.Cookies()
	if len(cookies) != 1 || cookies[0].Name != sessionCookieName {
		t.Fatalf("cookies: %+v", cookies)
	}
	if !cookies[0].HttpOnly {
		t.Fatal("the session cookie is not HttpOnly")
	}
	if cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("SameSite: %v", cookies[0].SameSite)
	}
	if second := exchange(issued.Code); second.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a code was accepted twice: %d", second.StatusCode)
	}
}

func TestALoginCodeNeedsACredentialToIssue(t *testing.T) {
	svc, _, _ := chatFixture(t)
	rec := chatCall(t, svc, http.MethodPost, "/v1/login/code", "", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}

func TestTheSignInPageCarriesItsPolicy(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	rec := chatCall(t, svc, http.MethodGet, "/ui/alpha", admin, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("page: %d", rec.Code)
	}
	for header, want := range map[string]string{
		"Content-Security-Policy": "default-src 'self'",
		"X-Content-Type-Options":  "nosniff",
		"X-Frame-Options":         "DENY",
		"Referrer-Policy":         "no-referrer",
	} {
		got := rec.Header().Get(header)
		if got == "" || !contains(got, want) {
			t.Fatalf("%s: %q", header, got)
		}
	}
}
