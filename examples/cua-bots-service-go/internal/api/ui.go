// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"net/http"
)

// The browser UI is embedded: one page, one stylesheet, one bundle. The bundle
// is built from ui/src by `npm run build` in ui/ and committed, so `go build`
// needs no Node toolchain.
//
//go:embed ui/index.html
var chatPage []byte

//go:embed ui/app.css
var chatCSS []byte

//go:embed ui/app.js
var chatJS []byte

// serveAsset answers a static UI file. The page and its assets are versioned
// together by ETag, so an open tab never runs yesterday's bundle against
// today's page.
func serveAsset(w http.ResponseWriter, r *http.Request, contentType string, body []byte) {
	sum := sha256.Sum256(body)
	tag := `"` + hex.EncodeToString(sum[:12]) + `"`
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("ETag", tag)
	if r.Header.Get("If-None-Match") == tag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	_, _ = w.Write(body)
}

// uiAsset answers the UI's own files and reports whether the path was one.
func (s *Service) uiAsset(w http.ResponseWriter, r *http.Request) bool {
	switch r.URL.Path {
	case "/ui/app.css":
		serveAsset(w, r, "text/css; charset=utf-8", chatCSS)
		return true
	case "/ui/app.js":
		serveAsset(w, r, "text/javascript; charset=utf-8", chatJS)
		return true
	default:
		return false
	}
}
