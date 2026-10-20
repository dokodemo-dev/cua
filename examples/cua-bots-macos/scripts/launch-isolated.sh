#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright (c) 2026 Cua AI, Inc.

# Launch the existing debug binary with temporary app data and a clean environment.
# This is not an OS sandbox; macOS preferences may still use the real account.
set -euo pipefail

if [[ ${1:-} == --help && $# == 1 ]]; then
  printf 'Usage: %s\nLaunch CuaBots with temporary data and no inherited credentials.\nSee launch-isolated.md for limitations.\n' "$0"
  exit 0
fi
if [[ $# != 0 ]]; then
  printf 'Usage: %s [--help]\n' "$0" >&2
  exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ ! -x .build/debug/CuaBots ]]; then
  printf 'CuaBots is not built. Run swift build --product CuaBots in examples/cua-bots-macos first.\n' >&2
  exit 1
fi

scratch="$(mktemp -d /tmp/cua-bots-gui.XXXXXX)"
printf 'Temporary app data (retained after exit): %s\n' "$scratch"
printf 'UI preview only. Do not create bots, sign in, or allow host access.\n'

exec env -i \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$scratch" \
  TMPDIR="$scratch/" \
  CUA_HOME="$scratch/.cua" \
  CUA_CREDENTIAL_STORE=file \
  CUA_TELEMETRY=0 \
  CUA_TELEMETRY_FORBID_NETWORK=1 \
  CUA_BOTS_DATA_DIR="$scratch/data" \
  CUA_BOTS_VOLUME="$scratch/volume" \
  CUA_BOTS_SYSTEM_NOTIFICATIONS=0 \
  CUA_BOTS_OWNER=test-user \
  CUA_BOTS_DEVICE_NAME=test-mac \
  .build/debug/CuaBots
