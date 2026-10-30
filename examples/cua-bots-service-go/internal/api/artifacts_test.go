// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
)

func listArtifacts(t *testing.T, svc *Service, botID, credential string) []domain.Artifact {
	t.Helper()
	rec := chatCall(t, svc, http.MethodGet, "/v1/bots/"+botID+"/artifacts", credential, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("list: %d %s", rec.Code, rec.Body)
	}
	var body struct {
		Artifacts []domain.Artifact `json:"artifacts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body.Artifacts
}

func tokenInSpace(t *testing.T, svc *Service, botID, spaceID string, now time.Time) string {
	t.Helper()
	value, err := svc.Tokens().Issue(botID, "default", &spaceID, domain.BotCapabilities, now, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestArtifactsAreListedNewestFirstForTheSpace(t *testing.T) {
	svc, _, now := chatFixture(t)
	alpha := tokenInSpace(t, svc, "alpha", "local:shared", now)
	beta := tokenInSpace(t, svc, "beta", "local:shared", now)
	first := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/artifacts", alpha,
		`{"spaceID":"local:shared","name":"report.md","byteCount":12,"sha256":"aa"}`)
	if first.Code != http.StatusCreated {
		t.Fatalf("register: %d %s", first.Code, first.Body)
	}
	second := chatCall(t, svc, http.MethodPost, "/v1/bots/alpha/artifacts", alpha,
		`{"spaceID":"local:shared","name":"chart.csv","byteCount":34,"sha256":"bb"}`)
	if second.Code != http.StatusCreated {
		t.Fatalf("register: %d %s", second.Code, second.Body)
	}
	// beta shares the Space, so it sees both; newest first.
	rows := listArtifacts(t, svc, "beta", beta)
	if len(rows) != 2 || rows[0].Name != "chart.csv" || rows[1].Name != "report.md" {
		t.Fatalf("rows: %+v", rows)
	}
	if rows[0].OwnerBotID != "alpha" || rows[0].ByteCount != 34 {
		t.Fatalf("row: %+v", rows[0])
	}
}

func TestArtifactsOfAnotherSpaceStayHidden(t *testing.T) {
	svc, _, now := chatFixture(t)
	alpha := tokenInSpace(t, svc, "alpha", "local:shared", now)
	if err := svc.Registry().AddBinding(domain.SpaceBinding{
		TargetID: "t1", Mode: domain.ModeShared, SpaceID: "local:other",
		Workspaces: map[string]string{"gamma": ""},
	}); err != nil {
		t.Fatal(err)
	}
	gamma := tokenInSpace(t, svc, "gamma", "local:other", now)
	rec := chatCall(t, svc, http.MethodPost, "/v1/bots/gamma/artifacts", gamma,
		`{"spaceID":"local:other","name":"secret.md","byteCount":1,"sha256":"cc"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register: %d %s", rec.Code, rec.Body)
	}

	if rows := listArtifacts(t, svc, "alpha", alpha); len(rows) != 0 {
		t.Fatalf("alpha saw another Space's artifact: %+v", rows)
	}
	admin := adminCredential(t, svc, now)
	if rows := listArtifacts(t, svc, "gamma", admin); len(rows) != 1 {
		t.Fatalf("gamma's artifacts: %+v", rows)
	}
}

func TestArtifactsNeedACredential(t *testing.T) {
	svc, _, _ := chatFixture(t)
	if rec := chatCall(t, svc, http.MethodGet, "/v1/bots/alpha/artifacts", "", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no credential: %d", rec.Code)
	}
}
