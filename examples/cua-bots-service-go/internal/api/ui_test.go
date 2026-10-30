// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The page and its assets ship together. A page that points at a stylesheet or
// bundle the server does not answer is a blank screen in the browser, which no
// other test would catch.
func TestUIServesThePageAndItsAssets(t *testing.T) {
	svc, _, _ := chatFixture(t)

	page := chatCall(t, svc, http.MethodGet, "/ui", "", "")
	if page.Code != http.StatusOK {
		t.Fatalf("page: status %d", page.Code)
	}
	body := page.Body.String()
	for _, want := range []string{"/ui/app.css", "/ui/app.js", `id="thread"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("page does not reference %q", want)
		}
	}

	for _, asset := range []struct{ path, contentType string }{
		{"/ui/app.css", "text/css; charset=utf-8"},
		{"/ui/app.js", "text/javascript; charset=utf-8"},
	} {
		rec := chatCall(t, svc, http.MethodGet, asset.path, "", "")
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", asset.path, rec.Code)
		}
		if rec.Body.Len() == 0 {
			t.Fatalf("%s: empty body", asset.path)
		}
		if got := rec.Header().Get("Content-Type"); got != asset.contentType {
			t.Fatalf("%s: content type %q", asset.path, got)
		}
		tag := rec.Header().Get("ETag")
		if tag == "" {
			t.Fatalf("%s: no ETag", asset.path)
		}

		req := httptest.NewRequest(http.MethodGet, asset.path, nil)
		req.RemoteAddr = "127.0.0.1:50000"
		req.Header.Set("If-None-Match", tag)
		cached := httptest.NewRecorder()
		svc.ServeHTTP(cached, req)
		if cached.Code != http.StatusNotModified {
			t.Fatalf("%s: cached read status %d", asset.path, cached.Code)
		}
	}
}

// Every /ui path is the same page: the browser decides what to show from it.
func TestThePageIsServedForABotPath(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	for _, path := range []string{"/ui", "/ui/alpha", "/ui/alpha/library", "/ui/settings/space"} {
		rec := chatCall(t, svc, http.MethodGet, path, admin, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d", path, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), "<title>Cua Bots</title>") {
			t.Fatalf("%s served something else", path)
		}
	}
}
