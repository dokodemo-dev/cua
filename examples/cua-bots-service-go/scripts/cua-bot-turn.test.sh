#!/usr/bin/env bash
# SPDX-License-Identifier: FSL-1.1-MIT
#
# Checks cua-bot-turn.sh's contract with the scheduler: the claim travels in the
# environment, the Cua CLI is invoked with the documented arguments, a new run's
# id is remembered, and a refusal or CLI failure exits non-zero so the scheduler
# records the slot as failed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
turn="$here/cua-bot-turn.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A stub cua that records its arguments instead of starting a Space.
stub="$work/cua"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CUA_STUB_LOG"
if [ "${CUA_STUB_FAIL:-0}" = "1" ]; then exit 3; fi
if [ "${CUA_STUB_LOGS_FAIL:-0}" = "1" ] && [ "$1 $2" = "agent logs" ]; then exit 3; fi
case "$1 $2" in
  "agent run") printf '{"harness":"pi","run_id":"run-42"}\n' ;;
  "agent logs")
    if [ "${CUA_STUB_ACP:-0}" = "1" ]; then
      printf 'agent.log [exited] ACP connection failed\n'
      exit 0
    fi
    # Each poll sees one more line, ending with a turn-end marker.
    n=$(cat "$CUA_STUB_LOGS" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$CUA_STUB_LOGS"
    i=1
    while [ "$i" -le "$n" ]; do printf 'line-%s\n' "$i"; i=$((i + 1)); done
    printf '[turn 1 ended: end_turn]\n' ;;
esac
exit 0
STUB
chmod +x "$stub"

pass=0
check() { # name, expected, actual
  local name="$1" want="$2" got="$3"
  if printf '%s' "$got" | grep -qF -- "$want"; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got" >&2
    exit 1
  fi
}
refuses() { # name, command...
  local name="$1"; shift
  if "$@" >"$work/err" 2>&1; then
    printf 'FAIL %s (it should have been refused)\n' "$name" >&2
    exit 1
  fi
  printf 'ok   %s\n' "$name"
  pass=$((pass + 1))
}

export CUA_BIN="$stub" CUA_STUB_LOG="$work/log" CUA_BOTS_RUN_DIR="$work/runs"
export CUA_BOTS_BOT_ID=alpha CUA_BOTS_PROMPT="Summarize" CUA_BOTS_DELIVERY_KEY=k1

# A stub curl answers the service call a scheduled delivery makes.
mkdir -p "$work/bin" "$work/tokens"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
if [ -n "${CUA_STUB_AGENT_JSON:-}" ]; then printf '%s' "$CUA_STUB_AGENT_JSON"; fi
exit 0
CURL
chmod +x "$work/bin/curl"
printf 'bot-token\n' >"$work/tokens/alpha.token"

# 1. A first delivery starts a run and remembers its id.
: >"$work/log"
"$turn" >"$work/out1" 2>&1
check "a new run is started" "agent run local:bot-alpha pi Summarize --json" "$(cat "$work/log")"
state="$work/runs/alpha.local_bot-alpha.run"
check "the run id is remembered, per Space" "run-42" "$(cat "$state")"

# 2. The next delivery follows up on that run, not a new one.
: >"$work/log"
"$turn" >/dev/null 2>&1
check "a follow-up goes to the same run" "agent send local:bot-alpha run-42 Summarize" "$(cat "$work/log")"

# 3. A custom Space and harness reach the CLI; model settings too.
: >"$work/log"
rm -f "$state"
CUA_BOTS_SPACE="local:shared" CUA_BOTS_HARNESS=codex \
  CUA_BOT_MODEL=test-model CUA_BOT_BASE_URL=http://127.0.0.1:1/v1 CUA_BOT_WIRE=openai-chat \
  CUA_BOT_KEY_VARS=OPENAI_API_KEY \
  "$turn" >/dev/null 2>&1
check "the Space, harness and model reach the CLI" \
  "agent run local:shared codex Summarize --model test-model --base-url http://127.0.0.1:1/v1 --wire openai-chat --env-from-host OPENAI_API_KEY --json" \
  "$(cat "$work/log")"


# 3a. A custom endpoint reads the run's key from OPENAI_API_KEY, so the Bot's
# own variable name is forwarded under that name.
: >"$work/log"
rm -f "$state"
DEEPSEEK_API_KEY=test-key CUA_BOT_MODEL=test-model \
  CUA_BOT_BASE_URL=http://127.0.0.1:1/v1 CUA_BOT_WIRE=openai-chat \
  CUA_BOT_KEY_VARS=DEEPSEEK_API_KEY \
  "$turn" >/dev/null 2>&1
check "an endpoint forwards the Bot's key variable as OPENAI_API_KEY" \
  "--env-from-host OPENAI_API_KEY --json" \
  "$(cat "$work/log")"
# 3a2. A scheduled delivery takes the Bot's own settings from the service,
# including the window that covers this hour.
: >"$work/log"
rm -f "$state"
PATH="$work/bin:$PATH" CUA_BOTS_TOKEN_DIR="$work/tokens" \
  CUA_BOTS_AGENT_URL=http://service.test \
  CUA_STUB_AGENT_JSON='{"set":true,"name":"opencode","env":{"CUA_BOTS_HARNESS":"pi","CUA_BOT_MODEL":"deepseek-v4.1-flash","CUA_BOT_BASE_URL":"https://opencode.ai/zen/go/v1","CUA_BOT_WIRE":"openai-chat","CUA_BOT_KEY_VARS":"OPENCODE_API_KEY","CUA_BOT_HEADERS":"x-opencode-session=cua-bots"}}' \
  "$turn" >/dev/null 2>&1
check "the service decides a scheduled delivery's model" \
  "agent run local:bot-alpha pi Summarize --model deepseek-v4.1-flash --base-url https://opencode.ai/zen/go/v1 --wire openai-chat --env-from-host OPENAI_API_KEY --header x-opencode-session=cua-bots --json" \
  "$(cat "$work/log")"

# 3a4. A key entered in the Web UI (keys.json) fills a gap turn.env left.
: >"$work/log"
rm -f "$state"
printf '{"keys": {"OLLAMA_API_KEY": {"value": "test-key"}}}' >"$work/keys.json"
PATH="$work/bin:$PATH" CUA_BOTS_KEYS_FILE="$work/keys.json" \
  CUA_BOT_BASE_URL=https://ollama.com/v1 CUA_BOT_WIRE=openai-chat \
  CUA_BOT_MODEL=deepseek-v4.1-flash:1017 CUA_BOT_KEY_VARS=OLLAMA_API_KEY \
  "$turn" >/dev/null 2>&1
check "a key stored by the Web UI reaches the CLI" \
  "--env-from-host OPENAI_API_KEY" "$(cat "$work/log")"

# 3a3. An unreachable service leaves turn.env's values in place.
: >"$work/log"
rm -f "$state"
PATH="$work/bin:$PATH" CUA_BOTS_TOKEN_DIR="$work/tokens" \
  CUA_BOTS_AGENT_URL=http://service.test CUA_STUB_AGENT_JSON='not json' \
  "$turn" >/dev/null 2>&1
check "a failed lookup falls back to the environment" \
  "agent run local:bot-alpha pi Summarize --json" \
  "$(cat "$work/log")"

# 3b. Extra endpoint headers reach the CLI as --header.
: >"$work/log"
rm -f "$state"
CUA_BOT_BASE_URL=http://127.0.0.1:1/v1 CUA_BOT_WIRE=openai-chat \
  CUA_BOT_MODEL=mimo-v2.6-flash CUA_BOT_KEY_VARS=OPENCODE_API_KEY \
  CUA_BOT_HEADERS="x-opencode-session=cua-bots" \
  "$turn" >/dev/null 2>&1
check "endpoint headers reach the CLI" \
  "--env-from-host OPENAI_API_KEY --header x-opencode-session=cua-bots --json" \
  "$(cat "$work/log")"

# 3c. A run the Space has forgotten is replaced, not retried forever.
: >"$work/log"
printf 'run-9\n' >"$state"
CUA_STUB_LOGS_FAIL=1 "$turn" >"$work/out3b" 2>&1
check "a stale run starts a new one" "agent run local:bot-alpha pi Summarize --json" "$(cat "$work/log")"
check "the stale id is replaced" "run-42" "$(cat "$state")"

# 3c. Re-pointing the Bot at another Space keeps the two runs apart.
: >"$work/log"
CUA_BOTS_SPACE=local:bot-other "$turn" >/dev/null 2>&1
check "another Space gets its own run" "agent run local:bot-other pi Summarize --json" "$(cat "$work/log")"
check "the first Space still remembers its run" "run-42" "$(cat "$state")"

# 3d. A guest with no agent login must be named, not retried until the timeout.
: >"$work/log"
rm -f "$state"
if CUA_STUB_ACP=1 CUA_BOT_MODE=wait CUA_BOT_WAIT_TIMEOUT=20 "$turn" >"$work/err" 2>&1; then
  printf 'FAIL an ACP failure should not look like a finished turn\n' >&2
  exit 1
fi
check "the missing login is explained" "not signed in yet" "$(cat "$work/err")"
rm -f "$state"

# 4. Refusals: an incomplete claim never reaches the CLI.
: >"$work/log"
refuses "a missing bot id is refused" env CUA_BOTS_BOT_ID= "$turn"
check "the refusal says which variable" "CUA_BOTS_BOT_ID is not set" "$(cat "$work/err")"
refuses "a missing prompt is refused" env CUA_BOTS_PROMPT= "$turn"
refuses "an unknown mode is refused" env CUA_BOT_MODE=sideways "$turn"
if [ -s "$work/log" ]; then
  printf 'FAIL nothing should reach the CLI when the claim is refused\n' >&2
  exit 1
fi
printf 'ok   nothing reached the CLI when the claim was refused\n'
pass=$((pass + 1))

# 5. A CLI failure is a failure, so the scheduler records the slot as failed.
rm -f "$state"
refuses "a failing CLI exits non-zero" env CUA_STUB_FAIL=1 "$turn"

# 6. Wait mode runs the turn and prints its log.
: >"$work/log"
rm -f "$state"
rm -f "$work/logs"
CUA_STUB_LOGS="$work/logs" CUA_BOT_MODE=wait "$turn" >"$work/out6" 2>&1
check "wait mode starts a run" "agent run local:bot-alpha pi Summarize --json" "$(cat "$work/log")"
check "wait mode reads the turn log" "agent logs local:bot-alpha run-42" "$(cat "$work/log")"
check "wait mode prints the reply" "line-1" "$(cat "$work/out6")"
check "the turn-end marker stays out of the reply" "0" \
  "$(grep -c 'ended' "$work/out6" || true)"

: >"$work/log"
rm -f "$work/logs"
printf 'run-9\n' >"$state"
CUA_STUB_LOGS="$work/logs" CUA_BOT_MODE=wait "$turn" >"$work/out7" 2>&1
check "wait mode sends to the same run" "agent send local:bot-alpha run-9 Summarize" "$(cat "$work/log")"
check "the follow-up hides the bookkeeping too" "0" \
  "$(grep -c 'ended' "$work/out7" || true)"
check "the follow-up still reports its run" "run=run-9" "$(cat "$work/out7")"

printf '%s checks passed\n' "$pass"
