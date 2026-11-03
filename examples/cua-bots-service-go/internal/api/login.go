// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
)

// loginPage hands the credential to the page's own storage and then opens the
// app. It exists because the alternatives both fail somewhere: a redirect can
// drop the fragment, and a cookie is refused by some browsers. Storing it here
// is a same-origin script write, which always works.
func loginPage(code, target, nonce string) []byte {
	// json.Marshal escapes quotes, angle brackets and the line separators that
	// would end a script early, so this literal is safe inside <script> as is.
	// HTML-escaping it would turn the quotes into entities and break the line.
	literal, _ := json.Marshal(code)
	if target == "" {
		target = "/ui"
	}
	path, _ := json.Marshal(target)
	page := `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><title>Cua Bots</title>
<meta name="referrer" content="no-referrer">
<style>body{font-family:system-ui,sans-serif;background:#0f1115;color:#e6e8ee;
display:grid;place-items:center;height:100vh;margin:0}</style></head>
<body><p>サインインしています…</p>
<script nonce="` + nonce + `">
try { localStorage.setItem("cua.session", ` + string(literal) + `); } catch (e) {}
location.replace(` + string(path) + `);
</script>
</body></html>`
	return []byte(page)
}
