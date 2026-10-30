// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/api"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/store"
)

func TestLoopbackNeedsNoPermissionButAnythingElseDoes(t *testing.T) {
	for _, bind := range []string{"127.0.0.1", "::1", "localhost"} {
		if err := checkBind(bind, false); err != nil {
			t.Fatalf("%s must be allowed by default: %v", bind, err)
		}
	}
	for _, bind := range []string{"0.0.0.0", "::", "example.invalid"} {
		if err := checkBind(bind, false); err == nil {
			t.Fatalf("%s must be refused without --allow-remote", bind)
		}
		if err := checkBind(bind, true); err != nil {
			t.Fatalf("%s must be allowed with --allow-remote: %v", bind, err)
		}
	}
}

func TestTLSServesTheSameRouter(t *testing.T) {
	dir := t.TempDir()
	certFile, keyFile := writeSelfSigned(t, dir)
	listener, err := listen("127.0.0.1", 0, certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})}
	go func() { _ = server.Serve(listener) }()
	defer func() { _ = server.Close() }()

	pool := x509.NewCertPool()
	pemBytes, err := os.ReadFile(certFile)
	if err != nil {
		t.Fatal(err)
	}
	pool.AppendCertsFromPEM(pemBytes)
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    pool,
	}}}
	address := listener.Addr().(*net.TCPAddr)
	response, err := client.Get("https://127.0.0.1:" + itoa(address.Port) + "/v1/health")
	if err != nil {
		t.Fatalf("TLS request failed: %v", err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("want 200 over TLS, got %d", response.StatusCode)
	}
	if response.TLS == nil || response.TLS.Version < tls.VersionTLS12 {
		t.Fatal("the connection must be TLS 1.2 or newer")
	}
}

func TestACertificateWithoutItsKeyIsRefused(t *testing.T) {
	if _, err := listen("127.0.0.1", 0, "/tmp/only-cert.pem", ""); err == nil {
		t.Fatal("a certificate without a key must be refused")
	}
}

func itoa(v int) string {
	if v == 0 {
		return "0"
	}
	var digits []byte
	for v > 0 {
		digits = append([]byte{byte('0' + v%10)}, digits...)
		v /= 10
	}
	return string(digits)
}

// writeSelfSigned makes a certificate for 127.0.0.1 in dir.
func writeSelfSigned(t *testing.T, dir string) (certFile, keyFile string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "cua-bots-test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certFile = filepath.Join(dir, "cert.pem")
	keyFile = filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	return certFile, keyFile
}

// A minted token must be written to the store as well as to the host file:
// otherwise the service that restarts later knows nothing about it, and the
// file authenticates nothing.
func TestMintedTokenStillAuthenticatesAfterReload(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()

	file, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	state, err := file.Load()
	if err != nil {
		t.Fatal(err)
	}
	service := api.New(state, file)
	if err := seed(service, "local:shared", "default", []string{"alpha"}, now); err != nil {
		t.Fatal(err)
	}
	token, err := mintBot(service, dir, "alpha", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := store.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reopened.Close() }()
	reloaded, err := reopened.Load()
	if err != nil {
		t.Fatal(err)
	}
	restarted := api.New(reloaded, reopened)
	if restarted.Tokens().Authenticate(token, now) == nil {
		t.Fatal("the minted token was not persisted")
	}

	onDisk, err := os.ReadFile(filepath.Join(dir, "alpha.token"))
	if err != nil {
		t.Fatal(err)
	}
	if string(onDisk) != token {
		t.Fatal("the token file and the token do not match")
	}
}
