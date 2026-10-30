# Phase 1 acceptance fixtures

These fixtures are for disposable OrbStack Spaces only. They are not production Pi extensions, shared skills, or host configuration. The tests use the SDK-pinned Pi 0.87.1, pi-acp 0.0.33, and codex-acp 1.13.1, not a real model.

## Prerequisites

- macOS with Swift/Xcode, OrbStack, and a built Cua CLI and `cua-mock-llm`.
- A `cua-spaces-ffi` library matching the Swift bindings. Do not overwrite a library used by a running application; stage and build inside an isolated source copy when necessary.
- Explicit approval before installing packages into the disposable guest. Verify publication age and SDK checksums. The pinned packages used in the recorded run were all older than seven days.
- A clean environment constructed with `isolatedEnvironment(root)` from `scripts/launch-mock.ts`. Never inherit production credentials or copy the host Pi profile.

## Prepare a Space

1. Create a temporary HOME with prefix `/tmp/cua-phase1-guest.`. The environment helper supplies the approved test placeholder, file-backed credentials, disabled telemetry and disabled system notifications.
2. With that environment, run the Cua CLI's `spaces create` for `ghcr.io/trycua/linux:24.04`, placement `local`, kind `container`, and a name beginning `phase1-`.
3. Run `agent ensure SPACE pi` and `agent ensure SPACE openai-codex` in the same isolated environment. The SDK verifies the pinned archives and installs only inside the guest.
4. Run the existing `cua-mock-llm --listen 127.0.0.1:18789`, setting its `CUA_MOCK_LLM_KEY` from the same helper's test-only `OPENAI_API_KEY`. The listen address must remain loopback, not `0.0.0.0`. Confirm the guest can reach `http://host.docker.internal:18789/health`.
5. Copy individual fixture files with `sb cp` (directory upload is not supported):
   - `extensions/phase1-probe/index.ts` to `/home/cua/phase1-pi/.pi/extensions/phase1-probe/index.ts`.
   - `skills/phase1-probe/SKILL.md` to `/home/cua/phase1-pi/.pi/skills/phase1-probe/SKILL.md`.
   - `profile/settings.json` and `profile/models.json` to `/home/cua/phase1-profile/`.

The dedicated guest profile trusts this authored test project and disables Pi install telemetry and retries. Do not apply its trust policy to ordinary user projects. The model configuration uses `$OPENAI_API_KEY` interpolation; a bare variable name is a literal string in Pi 0.87.1. The model URL must remain the local mock.

## Run the acceptance tests

Build the test executable first. Run the following from `examples/cua-bots-macos` (or the corresponding isolated source copy), inside the clean environment described above, with `CUA_HOME` pointing at its own registry, not the user's registry:

```sh
CUA_BOTS_RUN_PREPARED_ACCEPTANCE=1 CUA_PHASE1_SPACE=local:phase1-NAME \
  swift test --skip-build --filter PreparedAcceptanceTests
```

The runner rejects a HOME or Space outside the expected test prefixes, missing telemetry guards, and a non-test credential. Pi uses `BotRuntime.piAgentDirectory` and the guest profile through `CuaEngine`, not `--env-from-host` (that CLI flag accepts provider credentials only). The Skill expands a scripted mock instruction, calls the extension tool, and writes a guest-only marker. Pi and Codex then reconnect through newly constructed Stores and Engines and respond on the same Run IDs. Each harness Run is stopped when its test finishes. A failure must fail the test; a started process or a skipped test is not acceptance evidence.

The other opt-in contracts use separate disposable Spaces and remove them:

```sh
CUA_BOTS_RUN_SPACE_OWNERSHIP=1 \
  swift test --skip-build --filter botsReuseOnlyTheirOwnSpaceAndResetIsIsolated
CUA_BOTS_RUN_CUA_INTEGRATION=1 \
  swift test --skip-build --filter piRunsThroughCuaEngineAndResumesAfterSuspend
```

Use the isolated environment for those commands too. Without their opt-in flags, ordinary tests do not create Spaces or call models.

## GUI process restart

Seed a Bot identity only in a new test Volume, pointing to the prepared test Space and guest Pi profile, with no Run ID. Launch the freshly built `CuaBots` binary with that Volume and a separate test data directory. Remove `CUA_BOTS_MODEL_URL` from this launch environment so it does not conflict with the explicit Pi profile.

Send a scripted mock greeting through the GUI and record the saved Run ID, runtime, Space ID, message count, and cursor. Quit only that test process. Relaunch the same binary with the same test data without reseeding it. Verify the settings and IDs match semantically, the first reply appears exactly once, and a second GUI message advances the cursor and returns a reply on the same Run. Comparing JSON strings is insufficient because object key ordering may change.

## Cleanup and limits

Quit the test GUI, delete only the Space created by this procedure from its isolated registry, and stop its loopback mock server. Do not stop or delete other Bots or Spaces. Temporary test data and cached images may remain; no real credentials belong in them. The recorded Phase 1 scope excludes migration of old cursor-less state, VM selection, shared Spaces, the independent scheduler, real-model quality, and a production Cua Driver bridge. See `docs/custom-bots/test-results.md` for measured results.
