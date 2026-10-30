#!/bin/bash
# SPDX-License-Identifier: FSL-1.1-MIT
#
# Keep the viewer proxy pointed at the Space's current host port.
#
# A Space's viewer listens inside its container, and Docker maps it to a host
# port that changes when the Space is recreated. cua-view.service holds one
# fixed address, so without this the browser keeps showing a dead tunnel after
# a rebuild. Run it on a timer; it does nothing when the port still matches.
#
# usage: cua-view-follow.sh [space] [unit]
#   space  the Space whose viewer to follow (default: $CUA_VIEW_SPACE or local:bot-alpha)
#   unit   the proxy service to keep correct (default: /etc/systemd/system/cua-view.service)
set -euo pipefail

space="${1:-${CUA_VIEW_SPACE:-local:bot-alpha}}"
unit="${2:-/etc/systemd/system/cua-view.service}"
container="${space#*:}"

die() { printf 'cua-view-follow: %s\n' "$1" >&2; exit 1; }
[ -f "$unit" ] || die "no unit at $unit"

# The container publishes the viewer on 3211; find where Docker put it.
ports="$(docker ps --filter "name=^${container}$" --format '{{.Ports}}' 2>/dev/null || true)"
[ -n "$ports" ] || die "container $container is not running"
port="$(printf '%s' "$ports" | tr ',' '\n' | sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\)->3211\/tcp.*/\1/p' | head -1)"
[ -n "$port" ] || die "no host port is mapped to 3211 in $container"

current="$(sed -n 's/^ExecStart=.*systemd-socket-proxyd[[:space:]][[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$unit" | head -1)"
if [ "$current" = "$port" ]; then
  printf 'cua-view-follow: unchanged (%s -> 127.0.0.1:%s)\n' "$container" "$port"
  exit 0
fi

# Rewrite only that address, keeping everything else in the unit.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s|^\(ExecStart=.*systemd-socket-proxyd[[:space:]][[:space:]]*127\.0\.0\.1:\)[0-9][0-9]*|\1${port}|" "$unit" >"$tmp"
install -m 0644 "$tmp" "$unit"
systemctl daemon-reload
systemctl restart cua-view.service
printf 'cua-view-follow: 127.0.0.1:%s -> 127.0.0.1:%s for %s\n' "${current:-none}" "$port" "$container"
