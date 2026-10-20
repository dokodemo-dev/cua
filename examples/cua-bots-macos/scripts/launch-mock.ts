#!/usr/bin/env -S node --no-warnings
import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdtemp, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function isolatedEnvironment(root: string): NodeJS.ProcessEnv {
  return {
    PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: root,
    TMPDIR: `${root}/`,
    DOCKER_HOST: "unix:///var/run/docker.sock",
    CUA_HOME: `${root}/.cua`,
    CUA_CREDENTIAL_STORE: "file",
    CUA_DAEMON_NO_RELAY: "1",
    CUA_TELEMETRY: "0",
    CUA_TELEMETRY_FORBID_NETWORK: "1",
    CUA_BOTS_DATA_DIR: `${root}/data`,
    CUA_BOTS_VOLUME: `${root}/volume`,
    CUA_BOTS_SYSTEM_NOTIFICATIONS: "0",
    CUA_BOTS_OWNER: "test-user",
    CUA_BOTS_DEVICE_NAME: "test-mac",
    CUA_BOTS_MODEL_URL: "http://127.0.0.1:18788/v1",
    CUA_BOTS_MODEL: "test-model",
    CUA_BOTS_MODEL_KEY_VARS: "OPENAI_API_KEY",
    OPENAI_API_KEY: "test-key",
  };
}

// Plain JavaScript for the guest's Node, independent of TypeScript support.
export const mockSource = String.raw`
const { createServer } = require("node:http");
let count = 0;
const server = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ requests: count }));
    return;
  }
  if (req.method !== "POST" || req.url !== "/v1/chat/completions") {
    res.writeHead(404); res.end(); return;
  }
  if (req.headers.authorization !== "Bearer test-key") {
    res.writeHead(401); res.end(); return;
  }
  try {
    let body = "";
    for await (const part of req) {
      body += part;
      if (body.length > 1048576) { res.writeHead(413); res.end(); return; }
    }
    const input = JSON.parse(body);
    const answer = "GUI mock reply #" + (++count) + ". No real model was called.";
    const base = { id: "chatcmpl-gui-mock", created: 0, model: "test-model" };
    if (input.stream !== true) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ...base, object: "chat.completion", choices: [
        { index: 0, message: { role: "assistant", content: answer }, finish_reason: "stop" }
      ], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
    const send = (delta, finish_reason = null) => res.write("data: " + JSON.stringify({
      ...base, object: "chat.completion.chunk", choices: [{ index: 0, delta, finish_reason }]
    }) + "\n\n");
    send({ role: "assistant", content: "" });
    send({ content: answer });
    send({}, "stop");
    res.end("data: [DONE]\n\n");
  } catch { res.writeHead(400); res.end(); }
});
server.listen(Number(process.env.CUA_GUI_MOCK_PORT ?? 18788), "127.0.0.1", () => {
  console.log(server.address().port);
});
`;

async function main() {
  if (process.argv.includes("--help")) {
    console.log(
      "Usage: bash scripts/launch-mock.sh\nCreates one disposable Space and launches the GUI with its loopback mock.",
    );
    return;
  }
  if (process.argv.length !== 2) throw new Error("Unknown arguments; use --help");
  const appDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const cli = resolve(appDir, "../../libs/cua/target/release/cua");
  const app = resolve(appDir, ".build/debug/CuaBots");
  await Promise.all([access(cli, constants.X_OK), access(app, constants.X_OK)]);
  const root = await mkdtemp("/tmp/cua-bots-gui-mock.");
  const env = isolatedEnvironment(root);
  const name = `gui-${randomUUID().slice(0, 8)}`;
  const space = `local:bot-${name}`;
  let active: ReturnType<typeof spawn> | undefined;
  let stopped = false;
  const interrupt = () => {
    stopped = true;
    active?.kill("SIGTERM");
  };
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", interrupt);
  const run = (binary: string, args: string[], timeout: number) =>
    new Promise<void>((ok, fail) => {
      if (stopped) {
        fail(new Error("Interrupted"));
        return;
      }
      const child = spawn(binary, args, { cwd: appDir, env, stdio: "inherit", timeout });
      active = child;
      child.once("error", fail);
      child.once("exit", (code, signal) => {
        active = undefined;
        if (code === 0) ok();
        else fail(new Error(`${binary.split("/").pop()} exited (${code ?? signal})`));
      });
    });
  const cua = (...args: string[]) => run(cli, ["--embedded", ...args], 600_000);
  console.log(`Temporary data: ${root}\nBot name to enter: ${name}\nSpace: ${space}`);
  let created = false;
  try {
    console.log("[1/4] Creating the local test Space (no cloud)");
    await cua(
      "spaces",
      "create",
      "ghcr.io/trycua/linux:24.04",
      "--on",
      "local",
      "--kind",
      "container",
      "--name",
      `bot-${name}`,
    );
    created = true;
    console.log("[2/4] Starting the guest loopback mock");
    const source = resolve(root, "gui-mock.cjs");
    await writeFile(source, mockSource);
    await cua("sb", "cp", source, `${space}:/tmp/cua-bots-gui-mock.cjs`);
    await cua(
      "sb",
      "exec",
      space,
      "nohup node /tmp/cua-bots-gui-mock.cjs >/tmp/cua-bots-gui-mock.log 2>&1 </dev/null &",
    );
    await cua(
      "sb",
      "exec",
      space,
      "node -e 'let tries=0; async function probe(){try{const r=await fetch(\"http://127.0.0.1:18788/health\"); if(r.ok)process.exit(0);}catch{} if(++tries===50)process.exit(1); setTimeout(probe,100);} probe();'",
    );
    console.log("[3/4] Ensuring SDK-pinned Pi packages in the test Space only");
    await cua("agent", "ensure", space, "pi");
    console.log(
      `[4/4] GUI ready: create exactly '${name}', choose This Mac / Pi, leave all other settings blank.`,
    );
    console.log(
      "Expect GUI mock reply #1, then send two messages for #2 and #3. Quit this GUI to delete the test Space.",
    );
    await run(app, [], 0);
  } finally {
    // Cleanup stays scoped to the one successfully created Space in this private HOME.
    if (created) {
      stopped = false;
      console.log(`Deleting test Space ${space}`);
      try {
        await cua("spaces", "delete", space, "--force");
      } catch (error) {
        console.error(`Cleanup failed; retained at ${root}:`, error);
        process.exitCode = 1;
      }
    }
    process.off("SIGINT", interrupt);
    process.off("SIGTERM", interrupt);
    console.log(`Temporary data retained: ${root}`);
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
