// SPDX-License-Identifier: FSL-1.1-MIT
import assert from "node:assert/strict";
import { test } from "node:test";
import { CuaBotsAPIError, CuaBotsClient, isLoopbackURL } from "./client.ts";

function recorder(response: () => Response) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = async (url: string, init?: RequestInit) => {
    calls.push({ url, init: init ?? {} });
    return response();
  };
  return { calls, fetchImpl };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

test("only loopback service URLs are accepted", () => {
  assert.equal(isLoopbackURL("http://127.0.0.1:9000"), true);
  assert.equal(isLoopbackURL("http://[::1]:9000"), true);
  assert.equal(isLoopbackURL("http://localhost:9000"), false);
  assert.equal(isLoopbackURL("http://198.51.100.7:9000"), false);
  assert.equal(isLoopbackURL("file:///tmp/socket"), false);
  assert.throws(() => new CuaBotsClient("http://198.51.100.7:9000", "t"));
  assert.throws(() => new CuaBotsClient("http://127.0.0.1:9000", " "));
});

test("delegation sends the bearer token, body and one idempotency key", async () => {
  const { calls, fetchImpl } = recorder(() => json(201, { id: "task-1", depth: "1" }));
  const client = new CuaBotsClient("http://127.0.0.1:9000/", "secret", { fetch: fetchImpl });
  const result = await client.delegate("alpha", {
    to: "beta",
    spaceID: "local:shared",
    prompt: "Summarize",
    idempotencyKey: "k1",
    deadlineSeconds: 60,
  });
  assert.deepEqual(result, { id: "task-1", depth: "1" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://127.0.0.1:9000/v1/bots/alpha/delegate");
  assert.equal(calls[0].init.method, "POST");
  const headers = calls[0].init.headers as Record<string, string>;
  assert.equal(headers.authorization, "Bearer secret");
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    to: "beta",
    spaceID: "local:shared",
    prompt: "Summarize",
    idempotencyKey: "k1",
    deadlineSeconds: 60,
  });
});

test("service errors keep their status and message", async () => {
  const { fetchImpl } = recorder(() => json(409, { error: "idempotencyConflict" }));
  const client = new CuaBotsClient("http://127.0.0.1:9000", "secret", { fetch: fetchImpl });
  await assert.rejects(
    client.delegate("alpha", {
      to: "beta",
      spaceID: "local:shared",
      prompt: "Other",
      idempotencyKey: "k1",
      deadlineSeconds: 60,
    }),
    (error: unknown) => {
      assert.ok(error instanceof CuaBotsAPIError);
      assert.equal(error.status, 409);
      assert.equal(error.message, "idempotencyConflict");
      return true;
    },
  );
});

test("bot ids are encoded and each call gets its own timeout signal", async () => {
  const { calls, fetchImpl } = recorder(() => json(200, { messages: [] }));
  const client = new CuaBotsClient("http://127.0.0.1:9000", "secret", {
    fetch: fetchImpl,
    timeoutMs: 250,
  });
  await client.messages("../alpha");
  assert.equal(calls[0].url, "http://127.0.0.1:9000/v1/bots/..%2Falpha/messages");
  assert.ok(calls[0].init.signal instanceof AbortSignal);
});
