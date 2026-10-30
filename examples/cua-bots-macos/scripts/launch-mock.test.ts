import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { isolatedEnvironment, mockSource } from "./launch-mock.ts";

test("GUI environment has only isolated paths and the approved placeholder", () => {
  const env = isolatedEnvironment("/tmp/cua-gui-test");
  assert.equal(env.HOME, "/tmp/cua-gui-test");
  assert.equal(env.CUA_HOME, "/tmp/cua-gui-test/.cua");
  assert.equal(env.OPENAI_API_KEY, "test-key");
  assert.equal(env.CUA_BOTS_MODEL_URL, "http://127.0.0.1:18788/v1");
  assert.equal(env.CUA_BOTS_MODEL_KEY_VARS, "OPENAI_API_KEY");
  assert.equal(env.CUA_TELEMETRY, "0");
  assert.equal(env.CUA_TELEMETRY_FORBID_NETWORK, "1");
  assert.equal(env.ANTHROPIC_API_KEY, undefined);
  assert.equal(env.CUA_BOTS_SPACES, undefined);
  assert.equal(env.DOCKER_HOST, "unix:///var/run/docker.sock");
});

test(
  "loopback mock handles ordinary and streaming chat without forwarding",
  { timeout: 10_000 },
  async () => {
    const child = spawn(process.execPath, ["-e", mockSource], {
      env: { CUA_GUI_MOCK_PORT: "0" },
      stdio: ["ignore", "pipe", "inherit"],
    });
    try {
      const [data] = await once(child.stdout, "data");
      const port = Number(String(data).trim());
      assert.ok(port > 0);
      const base = `http://127.0.0.1:${port}`;
      assert.equal((await fetch(`${base}/health`)).status, 200);
      const request = (stream: boolean) =>
        fetch(`${base}/v1/chat/completions`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: "Bearer test-key" },
          body: JSON.stringify({ model: "test-model", messages: [], stream }),
        });
      assert.equal(
        (await fetch(`${base}/v1/chat/completions`, { method: "POST", body: "{}" })).status,
        401,
      );
      const first = await (await request(false)).json();
      assert.equal(
        first.choices[0].message.content,
        "GUI mock reply #1. No real model was called.",
      );
      const second = await (await request(true)).text();
      assert.match(second, /GUI mock reply #2/);
      assert.match(second, /data: \[DONE\]/);
      assert.equal((await fetch(`${base}/unknown`)).status, 404);
    } finally {
      child.kill();
      await once(child, "exit");
    }
  },
);
