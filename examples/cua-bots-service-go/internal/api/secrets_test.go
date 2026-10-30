// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestKeysAreStoredWithoutEverReadingBack(t *testing.T) {
	svc, _, now := chatFixture(t)
	svc.KeysPath = filepath.Join(t.TempDir(), "keys.json")
	admin := adminCredential(t, svc, now)

	rec := chatCall(t, svc, http.MethodPut, "/v1/keys/OLLAMA_API_KEY", admin,
		`{"value":"test-key-1234"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	var put keySummary
	if err := json.Unmarshal(rec.Body.Bytes(), &put); err != nil {
		t.Fatal(err)
	}
	if put.Last4 != "…1234" {
		t.Fatalf("last4: %q", put.Last4)
	}
	if body := rec.Body.String(); contains(body, "test-key-1234") {
		t.Fatalf("the value came back: %s", body)
	}

	// 0600, so only the service user can read the file.
	info, err := os.Stat(svc.KeysPath)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("mode: %o", mode)
	}
	body, err := os.ReadFile(svc.KeysPath)
	if err != nil {
		t.Fatal(err)
	}
	if !contains(string(body), "test-key-1234") {
		t.Fatal("the key is not in the file the turn script reads")
	}

	list := chatCall(t, svc, http.MethodGet, "/v1/keys", admin, "")
	if list.Code != http.StatusOK {
		t.Fatalf("list: %d %s", list.Code, list.Body)
	}
	if contains(list.Body.String(), "test-key-1234") {
		t.Fatalf("the list leaked the value: %s", list.Body)
	}
	if !contains(list.Body.String(), "OLLAMA_API_KEY") {
		t.Fatalf("the list has no name: %s", list.Body)
	}

	del := chatCall(t, svc, http.MethodDelete, "/v1/keys/OLLAMA_API_KEY", admin, "")
	if del.Code != http.StatusOK {
		t.Fatalf("delete: %d %s", del.Code, del.Body)
	}
	after := chatCall(t, svc, http.MethodGet, "/v1/keys", admin, "")
	if contains(after.Body.String(), "OLLAMA_API_KEY") {
		t.Fatalf("the key survived the delete: %s", after.Body)
	}
}

func TestKeysNeedAnAdministrator(t *testing.T) {
	svc, _, _ := chatFixture(t)
	svc.KeysPath = filepath.Join(t.TempDir(), "keys.json")
	bot := adminCredentialFor(t, svc, "alpha")
	for _, call := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodGet, "/v1/keys", ""},
		{http.MethodPut, "/v1/keys/OPENAI_API_KEY", `{"value":"x"}`},
		{http.MethodDelete, "/v1/keys/OPENAI_API_KEY", ""},
	} {
		rec := chatCall(t, svc, call.method, call.path, bot, call.body)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s %s: %d %s", call.method, call.path, rec.Code, rec.Body)
		}
	}
}

func TestBadKeysAreRefused(t *testing.T) {
	svc, _, now := chatFixture(t)
	svc.KeysPath = filepath.Join(t.TempDir(), "keys.json")
	admin := adminCredential(t, svc, now)
	for _, call := range []struct {
		path string
		body string
	}{
		{"/v1/keys/openai_api_key", `{"value":"x"}`},    // not a variable name
		{"/v1/keys/OPENAI_API_KEY", `{"value":""}`},     // empty
		{"/v1/keys/OPENAI_API_KEY", `{"value":"a\nb"}`}, // a control character
		{"/v1/keys/OPENAI_API_KEY", `not json`},
	} {
		rec := chatCall(t, svc, http.MethodPut, call.path, admin, call.body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s %s: %d %s", call.path, call.body, rec.Code, rec.Body)
		}
	}
}
