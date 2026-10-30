// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"os"
	"path/filepath"
)

// writeSecret writes a 0600 file holding a bearer value, for the hosts that
// keep one copy next to the state.
func writeSecret(dir, name, value string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(value+"\n"), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}
