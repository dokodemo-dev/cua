#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
#
# Checks cua-view-follow.sh against a fake unit and a fake `docker ps`: the
# viewer proxy must be repointed when the Space's host port changes, and left
# alone when it has not.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/cua-view-follow.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
check() { # name, expected, actual
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got" >&2
    exit 1
  fi
}

# A docker stub that reports a fixed port mapping.
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "${DOCKER_PORTS:-}"
STUB
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

unit="$work/cua-view.service"
write_unit() {
  cat >"$unit" <<EOF
[Service]
ExecStart=/lib/systemd/systemd-socket-proxyd 127.0.0.1:$1
PrivateTmp=yes
EOF
}
# systemctl is stubbed: we only record that it was asked to restart.
cat >"$work/bin/systemctl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$work/systemctl.log"
STUB
chmod +x "$work/bin/systemctl"

write_unit 32768
DOCKER_PORTS="3212/udp, 18080/tcp, 127.0.0.1:32770->3211/tcp" \
  "$script" local:bot-alpha "$unit" >"$work/out" 2>&1
check "the port is followed" "ExecStart=/lib/systemd/systemd-socket-proxyd 127.0.0.1:32770" \
  "$(grep ExecStart "$unit")"
check "the unit is reused" "PrivateTmp=yes" "$(grep PrivateTmp "$unit")"
check "the proxy is restarted" "1" "$(grep -c restart "$work/systemctl.log" || true)"

: >"$work/systemctl.log"
DOCKER_PORTS="3212/udp, 18080/tcp, 127.0.0.1:32770->3211/tcp" \
  "$script" local:bot-alpha "$unit" >"$work/out2" 2>&1
check "an unchanged port is left alone" "0" "$(grep -c restart "$work/systemctl.log" || true)"
check "it says so" "unchanged" "$(grep -o unchanged "$work/out2" | head -1)"

if DOCKER_PORTS="" "$script" local:bot-alpha "$unit" >"$work/err" 2>&1; then
  printf 'FAIL a missing container must fail\n' >&2
  exit 1
fi
check "a missing container is explained" "cua-view-follow: container bot-alpha is not running" "$(cat "$work/err")"

printf '%s checks passed\n' "$pass"
