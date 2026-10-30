#!/usr/bin/env -S node --no-warnings
// SPDX-License-Identifier: FSL-1.1-MIT
// Thin CLI over the service API, used for checks and by other harnesses.
import { readFile } from "node:fs/promises";
import { CuaBotsAPIError, CuaBotsClient } from "./client.ts";

function arg(name: string, fallback?: string): string {
  const index = process.argv.indexOf(`--${name}`);
  if (index > 0 && index + 1 < process.argv.length) return process.argv[index + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

async function client(): Promise<CuaBotsClient> {
  const url = process.env.CUA_BOTS_API_URL;
  if (!url) throw new Error("CUA_BOTS_API_URL is not set");
  const tokenFile = process.env.CUA_BOTS_TOKEN_FILE;
  const token = tokenFile ? (await readFile(tokenFile, "utf8")).trim() : process.env.CUA_BOTS_TOKEN;
  if (!token) throw new Error("CUA_BOTS_TOKEN_FILE or CUA_BOTS_TOKEN is required");
  return new CuaBotsClient(url, token);
}

async function main(): Promise<void> {
  const command = process.argv[2];
  const api = await client();
  switch (command) {
    case "health":
      console.log(JSON.stringify(await api.health()));
      return;
    case "messages":
      console.log(JSON.stringify(await api.messages(arg("bot"))));
      return;
    case "delegate":
      console.log(
        JSON.stringify(
          await api.delegate(arg("bot"), {
            to: arg("to"),
            spaceID: arg("space"),
            prompt: arg("prompt"),
            idempotencyKey: arg("key"),
            deadlineSeconds: Number(arg("deadline", "60")),
            ...(process.argv.includes("--parent") ? { parentID: arg("parent") } : {}),
          }),
        ),
      );
      return;
    case "message":
      console.log(
        JSON.stringify(
          await api.postMessage(arg("bot"), {
            spaceID: arg("space"),
            body: arg("body"),
            idempotencyKey: arg("key"),
            ...(process.argv.includes("--to") ? { to: arg("to") } : {}),
          }),
        ),
      );
      return;
    case "artifact":
      console.log(
        JSON.stringify(
          await api.artifact(arg("bot"), {
            spaceID: arg("space"),
            name: arg("name"),
            byteCount: Number(arg("bytes")),
            sha256: arg("sha256"),
          }),
        ),
      );
      return;
    default:
      throw new Error(`unknown command: ${command ?? "(none)"}`);
  }
}

main().catch((error: unknown) => {
  if (error instanceof CuaBotsAPIError) {
    console.error(JSON.stringify({ status: error.status, error: error.message }));
    process.exit(1);
  }
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
