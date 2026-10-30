#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
#
# Installs the Cua Bots service and scheduler on a Linux VPS.
#
#   ./install-vps.sh --bind <wg0 address> [--port 7717] [--apply]
#
# Without --apply it prints what it would do. With --apply it copies the two
# binaries next to this script into /usr/local/bin, creates the `cua-bots` user
# and /var/lib/cua-bots, writes both systemd units and enables them. It never
# writes a token; issue those with `cua-bots-service --admin` / `--mint`.
set -euo pipefail

bind=""
port="7717"
exec_command="/usr/local/bin/cua-bot-turn"
apply=false

while [ $# -gt 0 ]; do
  case "$1" in
    --bind) bind="${2:-}"; shift 2 ;;
    --port) port="${2:-}"; shift 2 ;;
    --exec-command) exec_command="${2:-}"; shift 2 ;;
    --apply) apply=true; shift ;;
    -h | --help)
      sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$bind" ] || {
  printf 'error: --bind is required (the WireGuard address this VPS holds)\n' >&2
  exit 2
}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$(cd "$here/.." && pwd)" # the binaries sit next to scripts/

run() {
  if $apply; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf 'would: %s\n' "$*"
  fi
}

for target in service scheduler; do
  [ -x "$dist/cua-bots-$target" ] || {
    printf 'error: %s is missing; build it first:\n' "$dist/cua-bots-$target" >&2
    printf '       go build -o cua-bots-%s ./cmd/cua-bots-%s\n' "$target" "$target" >&2
    exit 1
  }
done

run install -d -m 0755 /usr/local/bin
run install -m 0755 "$dist/cua-bots-service" /usr/local/bin/cua-bots-service
run install -m 0755 "$dist/cua-bots-scheduler" /usr/local/bin/cua-bots-scheduler
for turn in "$here/cua-bot-turn.sh" "$here/scripts/cua-bot-turn.sh"; do
  if [ -x "$turn" ]; then
    run install -m 0755 "$turn" /usr/local/bin/cua-bot-turn
    break
  fi
done

if ! id -u cua-bots >/dev/null 2>&1; then
  run useradd --system --home /var/lib/cua-bots --shell /usr/sbin/nologin cua-bots
fi
run install -d -m 0700 -o cua-bots -g cua-bots /var/lib/cua-bots
run install -d -m 0700 -o cua-bots -g cua-bots /var/lib/cua-bots/runs

# A VPN address is not loopback: the service needs --allow-remote to bind it.
remote=()
case "$bind" in
  127.0.0.1 | ::1 | localhost) ;;
  *) remote=(--allow-remote) ;;
esac
service_unit="$("$dist/cua-bots-service" --state /var/lib/cua-bots --bind "$bind" --port "$port" ${remote[@]+"${remote[@]}"} --print-systemd-unit)"
scheduler_unit="$("$dist/cua-bots-scheduler" --state /var/lib/cua-bots/scheduler --owner cua-bots \
  --exec-command "$exec_command" --print-systemd-unit)"

if $apply; then
  printf '%s\n' "$service_unit" >/etc/systemd/system/cua-bots-service.service
  printf '%s\n' "$scheduler_unit" >/etc/systemd/system/cua-bots-scheduler.service
  systemctl daemon-reload
  systemctl enable --now cua-bots-service.service cua-bots-scheduler.service
else
  printf '\n--- cua-bots-service.service ---\n%s\n' "$service_unit"
  printf '\n--- cua-bots-scheduler.service ---\n%s\n' "$scheduler_unit"
  printf '\nRun again with --apply to install and enable both.\n'
fi
