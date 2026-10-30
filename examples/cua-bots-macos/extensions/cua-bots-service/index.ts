// SPDX-License-Identifier: FSL-1.1-MIT
// Pi extension: lets the agent inside a Bot talk to the local Cua Bots service.
// The token is read per call from a file so it never enters the prompt.
import { readFile } from "node:fs/promises";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { CuaBotsClient } from "./client.ts";

async function client(): Promise<CuaBotsClient> {
  const url = process.env.CUA_BOTS_API_URL;
  if (!url) throw new Error("CUA_BOTS_API_URL is not set for this Bot.");
  const tokenFile = process.env.CUA_BOTS_TOKEN_FILE;
  if (!tokenFile) throw new Error("CUA_BOTS_TOKEN_FILE is not set for this Bot.");
  const token = (await readFile(tokenFile, "utf8")).trim();
  return new CuaBotsClient(url, token);
}

function botID(params: { botID?: string }): string {
  const id = params.botID ?? process.env.CUA_BOTS_ID;
  if (!id) throw new Error("Pass botID or set CUA_BOTS_ID.");
  return id;
}

function text(value: unknown) {
  return [{ type: "text" as const, text: JSON.stringify(value, null, 2) }];
}

const delegate = defineTool({
  name: "cua_bots_delegate",
  label: "Delegate to another Bot",
  description:
    "Hand one bounded task to another Bot in the same Space and trust group. Requires an idempotency key; repeat the same key to retry safely.",
  parameters: Type.Object({
    botID: Type.Optional(Type.String({ description: "Calling Bot id; defaults to CUA_BOTS_ID" })),
    to: Type.String({ description: "Recipient Bot id" }),
    spaceID: Type.String({ description: "Space both Bots are in" }),
    prompt: Type.String({ description: "The task" }),
    idempotencyKey: Type.String({ description: "Stable key for this request" }),
    deadlineSeconds: Type.Optional(Type.Number({ description: "Up to 1800, default 60" })),
    parentID: Type.Optional(Type.String({ description: "Parent task id when continuing a chain" })),
  }),
  async execute(_id, params) {
    const api = await client();
    const result = await api.delegate(botID(params), {
      to: params.to,
      spaceID: params.spaceID,
      prompt: params.prompt,
      idempotencyKey: params.idempotencyKey,
      deadlineSeconds: params.deadlineSeconds ?? 60,
      ...(params.parentID ? { parentID: params.parentID } : {}),
    });
    return { content: text(result), details: { result } };
  },
});

const messages = defineTool({
  name: "cua_bots_messages",
  label: "Read Bot messages",
  description: "List messages addressed to this Bot or to its Space.",
  parameters: Type.Object({
    botID: Type.Optional(Type.String({ description: "Defaults to CUA_BOTS_ID" })),
  }),
  async execute(_id, params) {
    const api = await client();
    const result = await api.messages(botID(params));
    return { content: text(result), details: { result } };
  },
});

const postMessage = defineTool({
  name: "cua_bots_post_message",
  label: "Post a message",
  description: "Post a note to the Bot's Space, optionally to one recipient.",
  parameters: Type.Object({
    botID: Type.Optional(Type.String({ description: "Defaults to CUA_BOTS_ID" })),
    spaceID: Type.String({ description: "Space to post in" }),
    body: Type.String({ description: "Message text" }),
    to: Type.Optional(Type.String({ description: "Recipient Bot id" })),
    idempotencyKey: Type.String({ description: "Stable key for this request" }),
  }),
  async execute(_id, params) {
    const api = await client();
    const result = await api.postMessage(botID(params), {
      spaceID: params.spaceID,
      body: params.body,
      idempotencyKey: params.idempotencyKey,
      ...(params.to ? { to: params.to } : {}),
    });
    return { content: text(result), details: { result } };
  },
});

const artifact = defineTool({
  name: "cua_bots_artifact",
  label: "Register an artifact",
  description:
    "Register a produced file with its size and SHA-256 so other Bots in the Space can find it. Files stay on the Bot's own disk.",
  parameters: Type.Object({
    botID: Type.Optional(Type.String({ description: "Defaults to CUA_BOTS_ID" })),
    spaceID: Type.String({ description: "Space the artifact belongs to" }),
    name: Type.String({ description: "File name without a path" }),
    byteCount: Type.Number({ description: "Size in bytes, at most 8 MiB" }),
    sha256: Type.String({ description: "Lowercase hex digest" }),
  }),
  async execute(_id, params) {
    const api = await client();
    const result = await api.artifact(botID(params), {
      spaceID: params.spaceID,
      name: params.name,
      byteCount: params.byteCount,
      sha256: params.sha256,
    });
    return { content: text(result), details: { result } };
  },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool(delegate);
  pi.registerTool(messages);
  pi.registerTool(postMessage);
  pi.registerTool(artifact);
}
