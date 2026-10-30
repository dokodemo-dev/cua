// SPDX-License-Identifier: FSL-1.1-MIT

package main

import (
	"strings"
	"testing"
)

func TestAPlaintextRemoteListenerWarns(t *testing.T) {
	warning := plaintextWarning("100.64.0.5", true, "")
	if warning == "" {
		t.Fatal("a remote listener without a certificate must warn")
	}
	for _, want := range []string{"plain HTTP", "containers", "tls"} {
		if !strings.Contains(warning, want) {
			t.Fatalf("the warning should mention %q: %s", want, warning)
		}
	}
}

func TestTheWarningStaysQuietWhenNothingIsExposed(t *testing.T) {
	cases := map[string]string{
		"loopback":        plaintextWarning("127.0.0.1", true, ""),
		"with a cert":     plaintextWarning("100.64.0.5", true, "cert.pem"),
		"no allow-remote": plaintextWarning("100.64.0.5", false, ""),
	}
	for name, got := range cases {
		if got != "" {
			t.Fatalf("%s must not warn, got %q", name, got)
		}
	}
}
