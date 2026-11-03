// Typed client for the cua-bots-service HTTP API.
//
// The service is the same one the Swift build exposes, so these shapes mirror
// internal/api/*.go. Keep them in step when an endpoint changes.

export type ColorName = 'cloud' | 'violet' | 'orange' | 'sky' | 'graphite' | 'slate';
export type EyeStyle = 'star' | 'round' | 'happy' | 'calm' | 'plus' | 'delight';
export type EarStyle = 'scalloped' | 'round' | 'small';

export interface Avatar {
  color: ColorName;
  eyes: EyeStyle;
  ears: EarStyle;
}

export interface BotsPayload {
  bots: string[];
  archived: string[];
  avatars: Record<string, Avatar>;
  spaces: Record<string, string>;
  /** When each Bot last started a turn (unix seconds). */
  activity?: Record<string, number>;
}

export type TurnStatus = 'running' | 'done' | 'failed';

export interface Turn {
  id: string;
  prompt: string;
  output: string;
  status: TurnStatus;
  error?: string;
  startedAt: number;
  endedAt?: number;
}

export interface ChatPayload {
  turns: Turn[];
  next: number;
}

export interface SpaceInfo {
  id: string;
  name: string;
  kind?: string;
  provider?: string;
  /** False when a Bot names a Space the host no longer lists. */
  registered?: boolean;
  /** The Bots that run in it. */
  bots?: string[];
  /** The state of a Bot in it when one is not ready yet. */
  state?: string;
}

export interface SpacesPayload {
  spaces: SpaceInfo[];
  note?: string;
}

export type SpaceStateName = 'pending' | 'ready' | 'failed';

export interface SpaceState {
  spaceID: string;
  state: SpaceStateName;
  detail?: string;
}

export interface Artifact {
  id: string;
  ownerBotID: string;
  spaceID: string;
  name: string;
  byteCount: number;
  sha256: string;
  createdAt: number;
}

export interface StoredKey {
  name: string;
  last4: string;
  updated?: string;
}

export interface AgentWindow {
  days?: string[];
  from?: string;
  to?: string;
  preset?: string;
  harness?: string;
  model?: string;
  baseURL?: string;
  wire?: string;
  keyVars?: string[];
  headers?: Record<string, string>;
}

export interface AgentSettings {
  harness?: string;
  provider?: string;
  model?: string;
  baseURL?: string;
  wire?: string;
  keyVars?: string[];
  headers?: Record<string, string>;
  windows?: AgentWindow[];
}

export interface AgentPayload {
  agent: AgentSettings;
  set: boolean;
  /** The one-line window form the dialog edits. */
  scheduleText?: string;
  /** The settings that apply right now, once the windows are resolved. */
  active?: AgentSettings;
  activeName?: string;
  /** When the applied window ends, and which one takes over. */
  until?: string;
  next?: string;
}

export interface Routine {
  id: string;
  title: string;
  prompt: string;
  everySec: number;
  nextRunAt: number;
  paused: boolean;
}

export interface SessionInfo {
  role: 'administrator' | 'bot';
  botID: string;
  capabilities: string[];
  expiresAt?: number;
  spaceID?: string;
}

export class ApiError extends Error {
  readonly status: number;
  readonly body: string;

  constructor(status: number, body: string) {
    super(body || `HTTP ${status}`);
    this.name = 'ApiError';
    this.status = status;
    this.body = body;
  }
}

// The session lives in an HttpOnly cookie: page script never holds the token,
// so a script injected into the page cannot read it out of storage. This key is
// only here to clear the copy older versions left in localStorage.
export const SESSION_KEY = 'cua.session';

function storage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

/** A credential an older version may still have stored. */
export function legacyCredential(): string {
  return (storage()?.getItem(SESSION_KEY) ?? '').trim();
}

export function clearCredential(): void {
  storage()?.removeItem(SESSION_KEY);
}

/**
 * Trades a one-time code, or a credential typed into the sign-in field, for the
 * session cookie. Nothing is kept: the browser holds the cookie and the page
 * never sees the token again.
 */
export async function exchangeLogin(input: { code?: string; token?: string }): Promise<boolean> {
  const res = await fetch('/v1/login/exchange', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(input),
    credentials: 'same-origin',
  });
  return res.ok;
}

/**
 * Reads the one-time code from the URL fragment, removes it from the address bar
 * before anything else, and trades it for the session cookie. A retired
 * `#k=<token>` link, and a stored credential from an older version, are refused
 * and cleared.
 */
export async function takeLoginFromURL(): Promise<'none' | 'ok' | 'failed' | 'retired'> {
  const hash = location.hash;
  const code = hash.startsWith('#c=') ? decodeURIComponent(hash.slice(3)) : '';
  if (hash) history.replaceState(null, '', location.pathname + location.search);
  if (legacyCredential()) clearCredential();
  if (!code) return hash.startsWith('#k=') ? 'retired' : 'none';
  return (await exchangeLogin({ code })) ? 'ok' : 'failed';
}

export function request(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  // The session travels in the HttpOnly cookie; fetch sends it for this origin.
  if (init.body !== undefined && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  return fetch(path, { ...init, headers, credentials: 'same-origin' });
}

export async function json<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await request(path, init);
  if (!res.ok) throw new ApiError(res.status, await res.text());
  return (await res.json()) as T;
}

function botPath(botID: string, suffix: string): string {
  return `/v1/bots/${encodeURIComponent(botID)}${suffix}`;
}

function managePath(botID: string, suffix: string): string {
  return `/v1/manage/bots/${encodeURIComponent(botID)}${suffix}`;
}

export const api = {
  bots(includeArchived: boolean): Promise<BotsPayload> {
    return json<BotsPayload>(includeArchived ? '/v1/bots?archived=1' : '/v1/bots');
  },

  spaces(): Promise<SpacesPayload> {
    return json<SpacesPayload>('/v1/spaces');
  },

  botSpace(botID: string): Promise<SpaceState> {
    return json<SpaceState>(botPath(botID, '/space'));
  },

  session(): Promise<SessionInfo> {
    return json<SessionInfo>('/v1/session');
  },

  turns(botID: string, after: number): Promise<ChatPayload> {
    return json<ChatPayload>(botPath(botID, `/chat?after=${after}`));
  },

  send(botID: string, prompt: string): Promise<Response> {
    return request(botPath(botID, '/chat'), {
      method: 'POST',
      body: JSON.stringify({ prompt }),
    });
  },

  pins(): Promise<{ bots: string[] }> {
    return json<{ bots: string[] }>('/v1/pins');
  },

  pin(botID: string): Promise<Response> {
    return request(`/v1/pins/${encodeURIComponent(botID)}`, { method: 'PUT' });
  },

  unpin(botID: string): Promise<Response> {
    return request(`/v1/pins/${encodeURIComponent(botID)}`, { method: 'DELETE' });
  },

  agent(botID: string): Promise<AgentPayload> {
    return json<AgentPayload>(botPath(botID, '/agent'));
  },

  setAgent(botID: string, settings: AgentSettings, scheduleText: string): Promise<Response> {
    return request(botPath(botID, '/agent'), {
      method: 'PUT',
      body: JSON.stringify({ ...settings, scheduleText }),
    });
  },

  keys(): Promise<{ keys: StoredKey[]; stored: boolean }> {
    return json<{ keys: StoredKey[]; stored: boolean }>('/v1/keys');
  },

  setKey(name: string, value: string): Promise<Response> {
    return request(`/v1/keys/${encodeURIComponent(name)}`, {
      method: 'PUT',
      body: JSON.stringify({ value }),
    });
  },

  removeKey(name: string): Promise<Response> {
    return request(`/v1/keys/${encodeURIComponent(name)}`, { method: 'DELETE' });
  },

  artifacts(botID: string): Promise<{ artifacts: Artifact[] }> {
    return json<{ artifacts: Artifact[] }>(botPath(botID, '/artifacts'));
  },

  routines(botID: string): Promise<{ routines: Routine[] }> {
    return json<{ routines: Routine[] }>(botPath(botID, '/routines'));
  },

  addRoutine(
    botID: string,
    routine: { title: string; prompt: string; everySec: number; delaySec: number }
  ): Promise<Response> {
    return request(botPath(botID, '/routines'), {
      method: 'POST',
      body: JSON.stringify(routine),
    });
  },

  changeRoutine(botID: string, jobID: string, action: 'pause' | 'resume'): Promise<Response> {
    return request(botPath(botID, `/routines/${encodeURIComponent(jobID)}/${action}`), {
      method: 'POST',
    });
  },

  deleteRoutine(botID: string, jobID: string): Promise<Response> {
    return request(botPath(botID, `/routines/${encodeURIComponent(jobID)}`), { method: 'DELETE' });
  },

  createBot(input: { name: string; spaceID: string; createSpace: boolean }): Promise<Response> {
    return request('/v1/manage/bots', {
      method: 'POST',
      body: JSON.stringify({
        botID: input.name,
        spaceID: input.spaceID,
        createSpace: input.createSpace,
      }),
    });
  },

  setAvatar(botID: string, avatar: Avatar): Promise<Response> {
    return request(managePath(botID, '/avatar'), {
      method: 'POST',
      body: JSON.stringify(avatar),
    });
  },

  archive(botID: string, archived: boolean): Promise<Response> {
    return request(managePath(botID, archived ? '/archive' : '/unarchive'), { method: 'POST' });
  },

  mintToken(botID: string): Promise<Response> {
    return request(managePath(botID, '/token'), { method: 'POST' });
  },
};