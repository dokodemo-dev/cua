// One small store for the whole page. The UI is a single screen, so a plain
// object plus explicit save/load helpers stays easier to follow than a
// framework, and keeps the bundle dependency-free.

import type {
  AgentSettings,
  Artifact,
  Avatar,
  ColorName,
  EarStyle,
  EyeStyle,
  Routine,
  SessionInfo,
  SpaceInfo,
  SpaceState,
  Turn,
} from './api';

export type PanelTab = 'details' | 'library' | 'computer';
/** How the rail groups and orders its Bots. */
export type RailSort = 'space' | 'name' | 'recent';
export type ThemePref = 'system' | 'light' | 'dark';

export const PREF = {
  bot: 'cua.bot',
  theme: 'cua.theme',
  thinking: 'cua.thinking.open',
  lastPrompts: 'cua.lastPrompts',
  railSort: 'cua.rail.sort',
} as const;

export interface AppState {
  signedIn: boolean;
  bots: string[];
  archived: string[];
  avatars: Record<string, Avatar>;
  botSpaces: Record<string, string>;
  /** When each Bot last started a turn (unix seconds). */
  botActivity: Record<string, number>;
  spaces: SpaceInfo[];
  spacesNote: string;
  current: string;
  turns: Turn[];
  cursor: number;
  routines: Routine[];
  session: SessionInfo | null;
  spaceStates: Record<string, SpaceState>;
  lastPrompts: Record<string, string>;
  pinned: string[];
  artifacts: Artifact[];
  artifactsBot: string;
  artifactsError: string;
  agent: AgentSettings;
  agentSet: boolean;
  agentBot: string;
  agentSchedule: string;
  agentActive: string;
  agentUntil: string;
  panelOpen: boolean;
  panelTab: PanelTab;
  sending: boolean;
}

export const state: AppState = {
  signedIn: false,
  bots: [],
  archived: [],
  avatars: {},
  botSpaces: {},
  botActivity: {},
  spaces: [],
  spacesNote: '',
  current: '',
  turns: [],
  cursor: 0,
  routines: [],
  session: null,
  spaceStates: {},
  lastPrompts: readJson<Record<string, string>>(PREF.lastPrompts) ?? {},
  pinned: [],
  artifacts: [],
  artifactsBot: '',
  artifactsError: '',
  agent: {},
  agentSet: false,
  agentBot: '',
  agentSchedule: '',
  agentActive: '',
  agentUntil: '',
  panelOpen: false,
  panelTab: 'details',
  sending: false,
};

function storage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

function readJson<T>(key: string): T | null {
  const raw = storage()?.getItem(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

export function preference(key: string): string | null {
  return storage()?.getItem(key) ?? null;
}

export function setPreference(key: string, value: string): void {
  storage()?.setItem(key, value);
}

export function removePreference(key: string): void {
  storage()?.removeItem(key);
}

export function rememberPrompt(botID: string, prompt: string): void {
  state.lastPrompts[botID] = prompt.replace(/\s+/g, ' ').trim().slice(0, 120);
  setPreference(PREF.lastPrompts, JSON.stringify(state.lastPrompts));
}

export function isPinned(botID: string): boolean {
  return state.pinned.includes(botID);
}

// The order comes from the service, newest first, so every device shows the
// same row. Drop ids that no longer exist (a Bot can be removed out of band).
export function applyPins(bots: string[]): void {
  state.pinned = bots.filter((id) => state.bots.includes(id));
}

export function thinkingOpenByDefault(): boolean {
  const value = preference(PREF.thinking);
  if (value === null) return true;
  return value === '1';
}

const COLOR_ORDER: ColorName[] = ['violet', 'orange', 'sky', 'cloud', 'slate', 'graphite'];

export function defaultAvatarFor(name: string): Avatar {
  let sum = 0;
  for (const ch of name) sum += ch.codePointAt(0) ?? 0;
  return {
    color: COLOR_ORDER[Math.abs(sum) % COLOR_ORDER.length] ?? 'sky',
    eyes: 'star',
    ears: 'scalloped',
  };
}

export const COLORS: ColorName[] = COLOR_ORDER;
export const EYES: EyeStyle[] = ['star', 'round', 'happy', 'calm', 'plus', 'delight'];
export const EARS: EarStyle[] = ['scalloped', 'round', 'small'];

export const COLOR_NAMES: Record<ColorName, string> = {
  violet: 'すみれ',
  orange: 'オレンジ',
  sky: 'そら',
  cloud: 'くも',
  slate: 'スレート',
  graphite: 'こく',
};

export const EYE_NAMES: Record<EyeStyle, string> = {
  star: '星',
  round: 'まる',
  happy: 'わらい',
  calm: 'ねむり',
  plus: 'プラス',
  delight: 'よろこび',
};

export const EAR_NAMES: Record<EarStyle, string> = {
  scalloped: 'なみ',
  round: 'まる',
  small: 'ちいさめ',
};

export function currentBot(): string {
  return state.current;
}

export function isArchived(botID: string): boolean {
  return state.archived.includes(botID);
}

export function spaceLabel(spaceID: string): string {
  if (!spaceID) return '未割り当て';
  if (spaceID === 'local') return 'ローカル';
  const known = state.spaces.find((space) => space.id === spaceID);
  if (known?.name) return known.name;
  // The Space list comes from the CLI and can be momentarily unavailable.
  // Derive the label from the id instead of collapsing every Bot into one
  // heading: `local:bot-alpha` reads as `bot-alpha`, which is also its Space
  // name, so the rail keeps its groups when that list is empty.
  const at = spaceID.indexOf(':');
  return at >= 0 ? spaceID.slice(at + 1) || spaceID : spaceID;
}