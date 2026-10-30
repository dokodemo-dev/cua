#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
# Copyright (c) 2026 Cua AI, Inc.
set -euo pipefail
exec node "$(dirname "${BASH_SOURCE[0]}")/launch-mock.ts" "$@"
