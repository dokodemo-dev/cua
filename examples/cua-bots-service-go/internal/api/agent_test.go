// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestAgentSettingsRoundTripAndSurviveARestart(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	body := `{"harness":"pi","provider":"openrouter","model":"deepseek/deepseek-v4",
		"baseURL":"https://openrouter.ai/api/v1","wire":"openai-chat",
		"keyVars":["OPENROUTER_API_KEY"]}`
	rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}

	get := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/agent", admin, "")
	if get.Code != http.StatusOK {
		t.Fatalf("get: %d %s", get.Code, get.Body)
	}
	settings, ok := svc.AgentFor("alpha")
	if !ok || settings.Model != "deepseek/deepseek-v4" || len(settings.KeyVars) != 1 {
		t.Fatalf("settings: %+v ok=%v", settings, ok)
	}

	restored := New(svc.Snapshot(), nil)
	after, ok := restored.AgentFor("alpha")
	if !ok || after.Provider != "openrouter" || after.BaseURL == "" {
		t.Fatalf("after restart: %+v ok=%v", after, ok)
	}
}

func TestAgentSettingsClearRestoresHostDefaults(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, `{"model":"gpt-6.1-sol"}`)

	rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, `{}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("clear: %d %s", rec.Code, rec.Body)
	}
	if _, ok := svc.AgentFor("alpha"); ok {
		t.Fatal("clearing should remove the entry, not store empty fields")
	}
}

func TestAgentSettingsValidateAndNeedAnAdmin(t *testing.T) {
	svc, botCredential, now := chatFixture(t)
	admin := adminCredential(t, svc, now)

	if rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", botCredential, `{}`); rec.Code != http.StatusForbidden {
		t.Fatalf("a Bot changed its own settings: %d", rec.Code)
	}
	for _, body := range []string{
		`not json`,
		`{"harness":"rm -rf"}`,
		`{"provider":"magic"}`,
		`{"model":"bad model"}`,
		`{"baseURL":"ftp://example.com"}`,
		`{"wire":"openai-chat"}`,
		`{"baseURL":"https://example.test/v1","wire":"xmlrpc"}`,
		`{"keyVars":["lower_case"]}`,
		`{"keyVars":["A","B","C","D","E"]}`,
	} {
		if rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, body); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", body, rec.Code, rec.Body)
		}
	}
}

func TestAgentChangeDeletesOnlyThatBotsRuns(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	dir := t.TempDir()
	svc.RunsDir = dir
	for _, name := range []string{"alpha.run", "alpha.local_bot-alpha.run", "beta.run"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("run"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, `{"model":"gpt-6.1-sol"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(filepath.Join(dir, "alpha.run")); !os.IsNotExist(err) {
		t.Fatal("alpha.run was not deleted")
	}
	if _, err := os.Stat(filepath.Join(dir, "alpha.local_bot-alpha.run")); !os.IsNotExist(err) {
		t.Fatal("alpha's other run was not deleted")
	}
	if _, err := os.Stat(filepath.Join(dir, "beta.run")); err != nil {
		t.Fatal("another Bot's run was deleted")
	}
}

func TestAgentSettingsAcceptTheDeepSeekHarness(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	body := `{"harness":"deepseek-harness","provider":"dsh","model":"",
		"baseURL":"","wire":"","keyVars":["DEEPSEEK_API_KEY"]}`
	rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	got, ok := svc.AgentFor("alpha")
	if !ok || got.Harness != "deepseek-harness" || got.Provider != "dsh" {
		t.Fatalf("agent: %+v ok=%v", got, ok)
	}
}

func TestAgentSettingsCarryEndpointHeaders(t *testing.T) {
	svc, _, now := chatFixture(t)
	admin := adminCredential(t, svc, now)
	body := `{"harness":"pi","provider":"opencode","model":"mimo-v2.6-flash",
		"baseURL":"https://opencode.ai/zen/go/v1","wire":"openai-chat",
		"keyVars":["OPENCODE_API_KEY"],
		"headers":{"x-opencode-session":"cua-bots"}}`
	rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("put: %d %s", rec.Code, rec.Body)
	}
	got, ok := svc.AgentFor("alpha")
	if !ok || got.Headers["x-opencode-session"] != "cua-bots" {
		t.Fatalf("headers: %+v ok=%v", got, ok)
	}
	// A header name that is not an HTTP token, or a value with a newline, is
	// refused rather than written into a config file.
	for _, bad := range []string{
		`{"headers":{"x session":"cua"}}`,
		`{"headers":{"x-session":"a\nb"}}`,
		`{"headers":{"x-session":""}}`,
	} {
		rec := chatCall(t, svc, http.MethodPut, "/v1/bots/alpha/agent", admin, bad)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: %d %s", bad, rec.Code, rec.Body)
		}
	}
}
