// SPDX-License-Identifier: FSL-1.1-MIT

// Command cua-bots-service serves the Bot collaboration API. It runs on Linux
// (VPS) as well as macOS; the Swift build under examples/cua-bots-macos remains
// the reference implementation and the local development path.
package main

import (
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/store"
)

func main() {
	var (
		stateDir    = flag.String("state", "", "state directory (required)")
		bind        = flag.String("bind", "127.0.0.1", "listen address (use the wg0 address on a VPS)")
		port        = flag.Int("port", 0, "listen port (0 picks one)")
		advertise   = flag.String("advertise", "", "URL written to api-url for Bots (default http://<bind>:<port>)")
		mint        = flag.String("mint", "", "issue a credential for this Bot and exit")
		rotate      = flag.String("rotate", "", "revoke this Bot's tokens, issue a new one and exit")
		revoke      = flag.String("revoke", "", "revoke this Bot's tokens and exit")
		admin       = flag.Bool("admin", false, "issue a registry-admin credential and exit")
		spaceID     = flag.String("space", "local:shared", "Space id used when seeding")
		trust       = flag.String("trust-group", "team-a", "trust group used when seeding")
		seedBots    = flag.String("seed-bots", "", "comma-separated Bot ids to seed into -space")
		allowRemote = flag.Bool("allow-remote", false, "bind a non-loopback address (a VPN address); required for anything but loopback")
		tlsCert     = flag.String("tls-cert", "", "serve HTTPS with this certificate (PEM)")
		tlsKey      = flag.String("tls-key", "", "the certificate's private key (PEM)")
		cuaBin      = flag.String("cua", "/usr/local/bin/cua", "cua CLI used to build a Space for a new Bot")
		noProvision = flag.Bool("no-provision", false, "do not build a Space when a Bot is created")
		provTimeout = flag.Duration("provision-timeout", 10*time.Minute, "how long a Space build may take")
		schedDir    = flag.String("scheduler-state", "/var/lib/cua-bots/scheduler", "where the scheduler keeps its state (read only)")
		runsDir     = flag.String("runs-dir", defaultRunsDir(), "where cua-bot-turn keeps one run id per Bot (deleted on a settings change)")
		turnCmd     = flag.String("turn-command", "/usr/local/bin/cua-bot-turn", "command that runs one chat turn")
		turnTTL     = flag.Duration("turn-timeout", 15*time.Minute, "how long one chat turn may run")
		systemd     = flag.Bool("print-systemd-unit", false, "print a systemd unit for this service and exit")
		execCmd     = flag.String("exec-command", "", "command the scheduler passes deliveries to (systemd unit)")
	)
	flag.Parse()
	if *stateDir == "" {
		log.Fatal("--state is required")
	}
	dir, err := filepath.Abs(*stateDir)
	if err != nil {
		log.Fatal(err)
	}
	// Printing a unit needs no state directory (and must work before the
	// service user and its directory exist).
	if *systemd {
		fmt.Print(systemdUnit(dir, *bind, *port, *execCmd))
		return
	}
	file, err := store.Open(dir)
	if err != nil {
		log.Fatal(err)
	}
	defer func() { _ = file.Close() }()

	state, err := file.Load()
	if err != nil {
		log.Fatal(err)
	}
	service := api.New(state, file)
	service.SetTurnRunner(turnRunner(*turnCmd, *turnTTL, service.SpaceOf, service.AgentFor))
	service.TokenLifetime = defaultTTL
	service.SchedulerDir = *schedDir
	service.RunsDir = *runsDir
	service.KeysPath = filepath.Join(dir, "keys.json")
	if sched, err := store.OpenSchedule(*schedDir); err == nil {
		service.Schedule = sched
	} else {
		log.Printf("warning: cannot write routines: %v", err)
	}
	service.SecretDir = dir
	if !*noProvision {
		service.Provisioner = cuaProvisioner(*cuaBin, *provTimeout)
		service.SpaceLister = cuaSpaceLister(*cuaBin, 20*time.Second, api.ParseSpaces)
	}
	now := time.Now()

	switch {
	case *admin:
		if _, err := mintAdmin(service, dir, now); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("ADMIN %s (host only)\n", filepath.Join(dir, "admin.token"))
		return
	case *mint != "":
		if _, err := mintBot(service, dir, *mint, now); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("MINTED %s -> %s\n", *mint, filepath.Join(dir, *mint+".token"))
		return
	case *rotate != "":
		service.Tokens().RevokeAll(*rotate, now)
		token, err := issueBot(service, *rotate, now)
		if err != nil {
			log.Fatal(err)
		}
		if err := writeSecret(dir, *rotate+".token", token); err != nil {
			log.Fatal(err)
		}
		if err := service.Save(); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("ROTATED %s (previous tokens are revoked)\n", *rotate)
		return
	case *revoke != "":
		service.Tokens().RevokeAll(*revoke, now)
		if err := service.Save(); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("REVOKED %s\n", *revoke)
		return
	}

	if *seedBots != "" {
		if err := seed(service, *spaceID, *trust, strings.Split(*seedBots, ","), now); err != nil {
			log.Fatal(err)
		}
		// Seeding is a one-shot command: the service itself runs from systemd,
		// so do not compete with it for the port.
		fmt.Printf("SEEDED %s into %s\n", *seedBots, *spaceID)
		return
	}

	if err := checkBind(*bind, *allowRemote); err != nil {
		log.Fatal(err)
	}
	if warning := plaintextWarning(*bind, *allowRemote, *tlsCert); warning != "" {
		log.Printf("warning: %s", warning)
	}
	listener, err := listen(*bind, *port, *tlsCert, *tlsKey)
	if err != nil {
		log.Fatal(err)
	}
	scheme := "http"
	if *tlsCert != "" {
		scheme = "https"
	}
	actualPort := listener.Addr().(*net.TCPAddr).Port
	advertised := *advertise
	if advertised == "" {
		advertised = fmt.Sprintf("%s://%s:%d", scheme, *bind, actualPort)
	}
	if err := os.WriteFile(filepath.Join(dir, "api-url"), []byte(advertised+"\n"), 0o600); err != nil {
		log.Fatal(err)
	}
	if *bind != "127.0.0.1" && *bind != "::1" {
		// A VPN address is not loopback: the token is the boundary.
		service.AllowRemote = true
	}
	server := &http.Server{
		Handler:           service,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
	}
	fmt.Printf("LISTEN %s\nADVERTISED %s\n", listener.Addr().String(), advertised)
	log.Fatal(server.Serve(listener))
}

// checkBind refuses to listen anywhere but loopback unless the operator says so
// explicitly: an accidental 0.0.0.0 must not expose the API to the internet.
func defaultRunsDir() string {
	if value := os.Getenv("CUA_BOTS_RUN_DIR"); value != "" {
		return value
	}
	return "/var/lib/cua-bots/runs"
}

func checkBind(bind string, allowRemote bool) error {
	if bind == "127.0.0.1" || bind == "::1" || bind == "localhost" {
		return nil
	}
	if !allowRemote {
		return fmt.Errorf("refusing to bind %q: pass --allow-remote for a VPN address, or bind 127.0.0.1", bind)
	}
	return nil
}

// plaintextWarning says what is not protected when a non-loopback listener has
// no certificate: WireGuard still encrypts the path to the VPN, but anything on
// this host (a container on the docker bridge, another tenant) reads plaintext.
func plaintextWarning(bind string, allowRemote bool, certFile string) string {
	if !allowRemote || certFile != "" {
		return ""
	}
	if bind == "127.0.0.1" || bind == "::1" || bind == "localhost" {
		return ""
	}
	return "serving " + bind + " over plain HTTP: WireGuard protects the tunnel, " +
		"but processes on this host (containers, other tenants) can read the tokens. " +
		"Pass --tls-cert and --tls-key when the host is shared or the API leaves the VPN. " +
		"See docs/custom-bots/vps-runbook.md (4.5)."
}

// listen serves HTTP, or HTTPS when a certificate is configured.
func listen(bind string, port int, certFile, keyFile string) (net.Listener, error) {
	address := net.JoinHostPort(bind, fmt.Sprint(port))
	if certFile == "" && keyFile == "" {
		return net.Listen("tcp", address)
	}
	if certFile == "" || keyFile == "" {
		return nil, fmt.Errorf("--tls-cert and --tls-key must be given together")
	}
	certificate, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("cannot load the certificate: %w", err)
	}
	return tls.Listen("tcp", address, &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{certificate},
	})
}

// mintBot issues a bot credential, writes it where the host can read it, and
// persists the digest. A token the store has not saved is lost the moment the
// service restarts, and the file it was written to then authenticates nothing.
func mintBot(service *api.Service, dir, botID string, now time.Time) (string, error) {
	token, err := issueBot(service, botID, now)
	if err != nil {
		return "", err
	}
	if err := writeSecret(dir, botID+".token", token); err != nil {
		return "", err
	}
	if err := service.Save(); err != nil {
		return "", err
	}
	return token, nil
}

// mintAdmin is mintBot for the registry administrator.
func mintAdmin(service *api.Service, dir string, now time.Time) (string, error) {
	token, err := issueAdmin(service, now)
	if err != nil {
		return "", err
	}
	if err := writeSecret(dir, "admin.token", token); err != nil {
		return "", err
	}
	if err := service.Save(); err != nil {
		return "", err
	}
	return token, nil
}

// defaultTTL is how long an issued credential lives. An hour was too short for
// a browser session; rotating and revoking are still the way to take one back.
const defaultTTL = 30 * 24 * time.Hour

func issueAdmin(service *api.Service, now time.Time) (string, error) {
	return service.Tokens().Issue("admin", "team-a", nil,
		[]domain.Capability{domain.CapManageRegistry}, now, defaultTTL)
}

func issueBot(service *api.Service, botID string, now time.Time) (string, error) {
	space := ""
	group := "team-a"
	for _, b := range service.Registry().Bindings {
		if _, ok := b.Workspaces[botID]; ok {
			space, group = b.SpaceID, b.Group()
			break
		}
	}
	if space == "" {
		return "", fmt.Errorf("unknown Bot: %s", botID)
	}
	return service.Tokens().Issue(botID, group, &space, domain.BotCapabilities, now, defaultTTL)
}

// writeSecret writes a 0600 file that holds a bearer value.
func writeSecret(dir, name, value string) error {
	path := filepath.Join(dir, name)
	return os.WriteFile(path, []byte(value), 0o600)
}

func seed(service *api.Service, spaceID, trust string, bots []string, now time.Time) error {
	registry := service.Registry()
	if _, ok := registry.Targets["local"]; !ok {
		if err := registry.AddTarget(domain.ExecutionTarget{
			ID: "local", Name: "This machine", Kind: domain.KindLocal,
		}); err != nil {
			return err
		}
	}
	if _, ok := registry.Bindings[spaceID]; !ok {
		if err := registry.AddBinding(domain.SpaceBinding{
			SpaceID: spaceID, TargetID: "local", Mode: domain.ModeShared,
			ManagedByApp: false, TrustGroup: trust,
			Workspaces: map[string]string{},
		}); err != nil {
			return err
		}
	}
	for _, raw := range bots {
		bot := strings.TrimSpace(raw)
		if bot == "" {
			continue
		}
		if err := registry.Assign(bot, spaceID, "/home/cua/bots/"+bot, trust); err != nil {
			return err
		}
	}
	service.Sync()
	return service.Save()
}

func systemdUnit(dir, bind string, port int, execCmd string) string {
	args := []string{"--state", dir, "--bind", bind}
	if port != 0 {
		args = append(args, "--port", fmt.Sprint(port))
	}
	// A VPN address needs the explicit opt-in; write it into the unit so the
	// service can start unattended.
	if bind != "127.0.0.1" && bind != "::1" && bind != "localhost" {
		args = append(args, "--allow-remote")
	}
	quoted := make([]string, 0, len(args))
	for _, a := range args {
		quoted = append(quoted, fmt.Sprintf("%q", a))
	}
	unit := fmt.Sprintf(`[Unit]
Description=Cua Bots collaboration service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/cua-bots/turn.env
ExecStart=/usr/local/bin/cua-bots-service %s
Restart=always
RestartSec=5
StateDirectory=cua-bots
User=cua-bots
Group=cua-bots
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
`, strings.Join(quoted, " "))
	if execCmd != "" {
		unit += fmt.Sprintf(`
# The scheduler runs the deliveries this command accepts:
# /usr/local/bin/cua-bots-scheduler --state %s/scheduler --owner cua-bots --exec-command %q
`, dir, execCmd)
	}
	return unit
}

// randomToken is unused in the default path but keeps a single source for
// token generation available to future subcommands.
func randomToken() string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

var _ = json.Marshal
var _ = randomToken
