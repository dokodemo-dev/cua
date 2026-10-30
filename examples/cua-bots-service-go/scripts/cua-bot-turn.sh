#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
#
# One scheduled delivery, handed to the Cua CLI. This is the production
# `--exec-command` for cua-bots-scheduler on a VPS:
#
#   cua-bots-scheduler --exec-command /usr/local/bin/cua-bot-turn \
#     --state /var/lib/cua-bots/scheduler --owner cua-bots
#
# The scheduler passes the claim in the environment:
#   CUA_BOTS_BOT_ID, CUA_BOTS_PROMPT, CUA_BOTS_DELIVERY_KEY, CUA_BOTS_ATTEMPT
#
# Optional:
#   CUA_BOTS_SPACE     Space that holds the Bot (default: local:bot-<id>)
#   CUA_BOTS_HARNESS   Harness for a new run (default: pi)
#   CUA_BOT_MODE       accept (default) or wait
#                      accept: the turn is queued and this exits 0
#                      wait:   this exits when the turn ends
#   CUA_BOTS_RUN_DIR   Where the Bot's run id is kept (default: /var/lib/cua-bots/runs)
#   CUA_BOT_MODEL, CUA_BOT_BASE_URL, CUA_BOT_WIRE, CUA_BOT_KEY_VARS,
#   CUA_BOT_HEADERS    Model, endpoint, wire format, comma-separated host
#                      variables for `--env-from-host`, and extra endpoint
#                      headers, for a new run
#   CUA_BOTS_AGENT_URL The service root. When set, the delivery asks the service
#                      which settings apply to this Bot right now (its own
#                      settings and time windows) instead of the values above.
#
# The first delivery starts a run and remembers its id; later ones send a
# follow-up to the same run, so the Bot keeps its session.
#
# Exit codes: 0 accepted (or finished, in wait mode); 1 refusal or failure.
set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

bot="${CUA_BOTS_BOT_ID:-}"
prompt="${CUA_BOTS_PROMPT:-}"
key="${CUA_BOTS_DELIVERY_KEY:-}"
[ -n "$bot" ] || fail "CUA_BOTS_BOT_ID is not set"
[ -n "$prompt" ] || fail "CUA_BOTS_PROMPT is not set"

cua="${CUA_BIN:-cua}"
command -v "$cua" >/dev/null 2>&1 || fail "cua CLI not found (set CUA_BIN)"
space="${CUA_BOTS_SPACE:-local:bot-$bot}"

# A scheduled delivery starts here, not in the service, so it asks the service
# which settings apply now (a Bot's own harness, model, endpoint, and the time
# window that covers this hour). Chat turns get the same values in their
# environment and skip this. Anything unreadable leaves turn.env's values.
apply_agent_env() {
  [ -n "${CUA_BOTS_AGENT_URL:-}" ] || return 0
  local tokfile="${CUA_BOTS_TOKEN_DIR:-/var/lib/cua-bots}/$bot.token"
  [ -r "$tokfile" ] || return 0
  local json
  json="$(curl -s -m 10 "${CUA_BOTS_AGENT_URL%/}/v1/bots/${bot}/agent/env" \
    -H "Authorization: Bearer $(cat "$tokfile")" 2>/dev/null)" || return 0
  [ -n "$json" ] || return 0
  local file
  file="$(mktemp)" || return 0
  printf '%s' "$json" | python3 -c '
import json, shlex, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
env = payload.get("env") or {}
for name, value in sorted(env.items()):
    if not isinstance(value, str):
        continue
    sys.stdout.write("export %s=%s\n" % (name, shlex.quote(value)))
' >"$file" 2>/dev/null || { rm -f "$file"; return 0; }
  [ -s "$file" ] || { rm -f "$file"; return 0; }
  # shellcheck disable=SC1090
  . "$file"
  rm -f "$file"
}
apply_agent_env

# Keys entered in the Web UI live in one 0600 file next to the Bot tokens. A
# value already in the environment (turn.env) wins; this only fills the gaps, so
# a key can be added without editing turn.env over SSH.
keys_file="${CUA_BOTS_KEYS_FILE:-/var/lib/cua-bots/keys.json}"
stored_key() { # name
  [ -r "$keys_file" ] || return 0
  python3 - "$keys_file" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    keys = json.load(open(sys.argv[1])).get("keys") or {}
except (OSError, ValueError):
    sys.exit(0)
entry = keys.get(sys.argv[2])
if isinstance(entry, dict):
    value = entry.get("value")
    if isinstance(value, str):
        sys.stdout.write(value)
PY
}
fill_stored_key() { # name
  local name="$1"
  [ -n "$name" ] || return 0
  [ -n "${!name:-}" ] && return 0
  local value
  value="$(stored_key "$name")"
  [ -n "$value" ] || return 0
  export "$name=$value"
}

harness="${CUA_BOTS_HARNESS:-pi}"
mode="${CUA_BOT_MODE:-accept}"
runs="${CUA_BOTS_RUN_DIR:-/var/lib/cua-bots/runs}"
mkdir -p "$runs"
# The run belongs to a Space, so the remembered run is per Space: re-pointing a
# Bot at a new Space must not try to send to the old one's run id.
slug="$(printf '%s' "$space" | tr -c 'A-Za-z0-9_.-' '_')"
state="$runs/$bot.$slug.run"

# A new run's model and endpoint, when configured.
model_args=()
[ -n "${CUA_BOT_MODEL:-}" ] && model_args+=(--model "$CUA_BOT_MODEL")
if [ -n "${CUA_BOT_BASE_URL:-}" ]; then
  model_args+=(--base-url "$CUA_BOT_BASE_URL")
  [ -n "${CUA_BOT_WIRE:-}" ] && model_args+=(--wire "$CUA_BOT_WIRE")
fi
if [ -n "${CUA_BOT_KEY_VARS:-}" ]; then
  IFS=',' read -r -a vars <<<"$CUA_BOT_KEY_VARS"
  if [ -n "${CUA_BOT_BASE_URL:-}" ]; then
    # A custom endpoint speaks OpenAI Chat Completions, and the harnesses
    # read the run's key from OPENAI_API_KEY. Forward the first named host
    # variable under that name, for this run only.
    first="${vars[0]:-}"
    if [ -n "$first" ]; then
      fill_stored_key "$first"
      if [ -n "${!first:-}" ]; then
        OPENAI_API_KEY="${!first}"
        export OPENAI_API_KEY
      fi
      model_args+=(--env-from-host OPENAI_API_KEY)
    fi
  else
    for v in "${vars[@]}"; do
      [ -n "$v" ] || continue
      fill_stored_key "$v"
      model_args+=(--env-from-host "$v")
    done
  fi
fi

if [ -n "${CUA_BOT_HEADERS:-}" ]; then
  # name=value pairs, `;`-separated: extra request headers the endpoint needs
  # (OpenCode Go routes on x-opencode-session). Never a credential.
  IFS=';' read -r -a pairs <<<"$CUA_BOT_HEADERS"
  for pair in "${pairs[@]}"; do
    [ -n "$pair" ] && model_args+=(--header "$pair")
  done
fi

# One line to stderr: which provider this turn resolved to. The service keeps
# stderr for the failure message, so a turn that cannot authenticate says what
# it tried. Names and ids only, never a key.
line=$(printf 'turn settings: harness=%s model=%s base=%s wire=%s keys=%s headers=%s' \
  "$harness" "${CUA_BOT_MODEL:-}" "${CUA_BOT_BASE_URL:-}" "${CUA_BOT_WIRE:-}" \
  "${CUA_BOT_KEY_VARS:-}" "${CUA_BOT_HEADERS:-}")
printf '%s\n' "$line" >&2
printf '%s %s\n' "$(date -u +%FT%TZ)" "$line" >>"$runs/turn-settings.log" 2>/dev/null || true
tail -n 200 "$runs/turn-settings.log" >"$runs/turn-settings.log.tmp" 2>/dev/null &&
  mv "$runs/turn-settings.log.tmp" "$runs/turn-settings.log" 2>/dev/null || true


follow=()
[ "$mode" = "accept" ] || [ "$mode" = "wait" ] || fail "unknown CUA_BOT_MODE: $mode"

# wait mode streams the turn's log, so the chat window sees the reply as it
# arrives. The CLI's own --follow returns before a stored run's turn ends, so the
# log itself is the stream we can trust.
# report files a finished turn with the service, so a routine's run shows up in
# the same chat window as a turn started from the browser. It is off unless
# CUA_BOTS_REPORT_URL is set (the scheduler's environment sets it).
report() { # status, output-file
  [ -n "${CUA_BOTS_REPORT_URL:-}" ] || return 0
  local tokfile="${CUA_BOTS_TOKEN_DIR:-/var/lib/cua-bots}/$bot.token"
  [ -r "$tokfile" ] || return 0
  local payload
  payload="$(python3 - "$prompt" "$2" "$1" <<'PY'
import json, sys
prompt, path, status = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    output = open(path, encoding='utf-8', errors='replace').read()
except OSError:
    output = ''
print(json.dumps({'prompt': prompt, 'output': output, 'status': status}))
PY
)" || return 0
  curl -s -m 10 -o /dev/null -X POST "${CUA_BOTS_REPORT_URL%/}/v1/bots/${bot}/chat/record" \
    -H "Authorization: Bearer $(cat "$tokfile")" \
    -H 'Content-Type: application/json' -d "$payload" || true
}

run_turn() { # start: how many log lines already existed
  local printed="${1:-0}" lines chunk
  local timeout="${CUA_BOT_WAIT_TIMEOUT:-900}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    lines="$("$cua" agent logs "$space" "$run" 2>/dev/null || true)"
    local total
    total="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
    if [ "$total" -gt "$printed" ]; then
      chunk="$(printf '%s\n' "$lines" | tail -n +"$((printed + 1))")"
      printed="$total"
      # The chat should read like a reply: keep the agent's words, drop this
      # script's own markers. The markers are still read from the raw chunk:
      # they are how this loop knows the turn ended.
      shown="$(printf '%s\n' "$chunk" | grep -v -e '^turn bot=' -e '^\[turn .* ended' || true)"
      [ -n "$shown" ] && printf '%s\n' "$shown"
      if printf '%s\n' "$chunk" | grep -q '\[turn .* ended'; then break; fi
      # A fresh Space has no agent login yet. Say so instead of printing the
      # same ACP line until the timeout.
      if printf '%s\n' "$chunk" | grep -q 'ACP connection failed'; then
        fail "the agent could not start in $space: it is not signed in yet (run the login inside that Space)"
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "the turn did not finish within ${timeout}s"
    fi
    sleep 2
  done
}

# A run carries the settings it was started with (its model, endpoint and key).
# When those change — a Bot setting from the browser, or the host defaults in
# turn.env — the old run cannot pick them up, so start a new one instead of
# sending every later turn to a run that still has the old model.
settings_file="$state.settings"
settings_now="harness=$harness model=${CUA_BOT_MODEL:-} base=${CUA_BOT_BASE_URL:-} wire=${CUA_BOT_WIRE:-} keys=${CUA_BOT_KEY_VARS:-} headers=${CUA_BOT_HEADERS:-}"
if [ -s "$state" ] && [ "$(cat "$settings_file" 2>/dev/null || true)" != "$settings_now" ]; then
  printf 'note: settings changed, starting a new run\n' >&2
  rm -f "$state"
fi
printf '%s' "$settings_now" >"$settings_file"

if [ -s "$state" ]; then
  run="$(cat "$state")"
  # A run the Space no longer knows (deleted, or the Bot moved) is not one we
  # can continue; forget it and start fresh instead of failing every turn.
  if ! "$cua" agent logs "$space" "$run" >/dev/null 2>&1; then
    rm -f "$state"
    printf 'note: run %s is gone from %s, starting a new one\n' "$run" "$space"
  fi
fi

if [ -s "$state" ]; then
  run="$(cat "$state")"
  printf 'turn bot=%s run=%s key=%s mode=%s\n' "$bot" "$run" "$mode" >&2
  if [ "$mode" = "wait" ]; then
    start="$("$cua" agent logs "$space" "$run" 2>/dev/null | wc -l | tr -d ' ')"
    output_file="$(mktemp)"
    "$cua" agent send "$space" "$run" "$prompt" >/dev/null || fail "the CLI refused the follow-up"
    run_turn "$start" | tee "$output_file"
    report done "$output_file"
    rm -f "$output_file"
    exit 0
  fi
  "$cua" agent send "$space" "$run" "$prompt" || fail "the CLI refused the follow-up"
  exit 0
fi

printf 'turn bot=%s space=%s key=%s mode=%s new-run\n' "$bot" "$space" "$mode" >&2
if [ "$mode" = "wait" ]; then
  started="$("$cua" agent run "$space" "$harness" "$prompt" "${model_args[@]}" --json)" || fail "the CLI could not start the run"
  printf '%s\n' "$started"
  run="$(printf '%s' "$started" | sed -n 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$run" ] || fail "the CLI did not report a run id"
  printf '%s\n' "$run" >"$state"
  output_file="$(mktemp)"
  run_turn | tee "$output_file"
  report done "$output_file"
  rm -f "$output_file"
  exit 0
fi

report="$("$cua" agent run "$space" "$harness" "$prompt" "${model_args[@]}" --json)"
printf '%s\n' "$report"
run="$(printf '%s' "$report" | sed -n 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$run" ] || fail "the CLI did not report a run id"
printf '%s\n' "$run" >"$state"
