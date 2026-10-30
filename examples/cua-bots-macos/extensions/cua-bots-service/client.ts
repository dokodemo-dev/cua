// SPDX-License-Identifier: FSL-1.1-MIT
// Client for the Cua Bots service. No Pi imports, so it runs under plain Node
// and can be tested with an injected fetch.

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export class CuaBotsAPIError extends Error {
  status: number;
  body: unknown;

  constructor(status: number, message: string, body: unknown) {
    super(message);
    this.name = "CuaBotsAPIError";
    this.status = status;
    this.body = body;
  }
}

/** The service is meant to stay on this Mac; refuse anything else. */
export function isLoopbackURL(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  const host = url.hostname.toLowerCase();
  return host === "127.0.0.1" || host === "::1" || host === "[::1]";
}

export interface DelegateInput {
  to: string;
  spaceID: string;
  prompt: string;
  idempotencyKey: string;
  deadlineSeconds: number;
  parentID?: string;
}

export interface MessageInput {
  spaceID: string;
  body: string;
  to?: string;
  idempotencyKey: string;
}

export interface ArtifactInput {
  spaceID: string;
  name: string;
  byteCount: number;
  sha256: string;
}

export class CuaBotsClient {
  readonly baseURL: string;
  readonly #token: string;
  readonly #fetch: FetchLike;
  readonly #timeoutMs: number;

  constructor(baseURL: string, token: string, options: {
    fetch?: FetchLike;
    timeoutMs?: number;
  } = {}) {
    if (!isLoopbackURL(baseURL)) {
      throw new Error(`refusing a non-loopback service URL: ${baseURL}`);
    }
    if (token.trim() === "") throw new Error("a service token is required");
    this.baseURL = baseURL.replace(/\/+$/, "");
    this.#token = token;
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
    this.#timeoutMs = options.timeoutMs ?? 15000;
  }

  health(): Promise<unknown> {
    return this.#request("GET", "/v1/health");
  }

  messages(botID: string): Promise<unknown> {
    return this.#request("GET", `/v1/bots/${encodeURIComponent(botID)}/messages`);
  }

  postMessage(botID: string, input: MessageInput): Promise<unknown> {
    return this.#request("POST", `/v1/bots/${encodeURIComponent(botID)}/messages`, input);
  }

  delegate(botID: string, input: DelegateInput): Promise<unknown> {
    return this.#request("POST", `/v1/bots/${encodeURIComponent(botID)}/delegate`, input);
  }

  artifact(botID: string, input: ArtifactInput): Promise<unknown> {
    return this.#request("POST", `/v1/bots/${encodeURIComponent(botID)}/artifacts`, input);
  }

  async #request(method: string, path: string, body?: unknown): Promise<unknown> {
    const response = await this.#fetch(`${this.baseURL}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.#token}`,
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(this.#timeoutMs),
    });
    const text = await response.text();
    let parsed: unknown = null;
    try {
      parsed = text === "" ? null : JSON.parse(text);
    } catch {
      parsed = text;
    }
    if (!response.ok) {
      const message = (parsed as { error?: string } | null)?.error ?? `HTTP ${response.status}`;
      throw new CuaBotsAPIError(response.status, message, parsed);
    }
    return parsed;
  }
}
