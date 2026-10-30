// The conversation column: polling, turn rendering, the composer, and the
// status pill at the top of the thread.

import { ApiError, api, type Turn, type TurnStatus } from './api';
import { koalaHtml, type Mood } from './avatar';
import { actions } from './deps';
import { copyText, el, fmtRelative, icon, toast } from './dom';
import { renderMarkdown } from './markdown';
import {
  PREF,
  preference,
  rememberPrompt,
  setPreference,
  state,
  thinkingOpenByDefault,
} from './store';

const NOISE = [
  /^turn bot=/,
  /^\[install\]/,
  /^\[notice\]/,
  /^\[turn \d+ ended/,
  /^\{"harness":/,
  // Pi prints an upgrade hint on every turn; it is not part of the answer.
  /^New version available: v/,
  /^Run: .*npm i -g/,
];

const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

let spinFrame = 0;
let timer = 0;
let thread: HTMLElement | null = null;
let viewport: HTMLElement | null = null;
let composer: HTMLFormElement | null = null;
let input: HTMLTextAreaElement | null = null;
let sendButton: HTMLButtonElement | null = null;
const boxes = new Map<string, HTMLElement>();

function cleanOutput(text: string): string {
  return String(text || '')
    .split('\n')
    .filter((line) => !NOISE.some((re) => re.test(line.trim())))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

// pi keeps the model's reasoning apart from its answer; so does this. The agent
// streams thinking as "[thinking] ..." lines, which belong in a quiet block.
export function splitOutput(text: string): { thinking: string; answer: string } {
  const lines = cleanOutput(text).split('\n');
  let last = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (/^\s*\[thinking\]/.test(lines[index] ?? '')) last = index;
  }
  if (last < 0) return { thinking: '', answer: lines.join('\n').trim() };
  const thinking = lines
    .slice(0, last + 1)
    .map((line) => line.replace(/^\s*\[thinking\]\s?/, ''))
    .join('\n')
    .trim();
  return {
    thinking,
    answer: lines
      .slice(last + 1)
      .join('\n')
      .trim(),
  };
}

function renderThinking(box: HTMLElement, thinking: string): void {
  let details = box.querySelector<HTMLDetailsElement>('.think');
  if (!thinking) {
    details?.remove();
    return;
  }
  if (!details) {
    details = el('details', { class: 'think' });
    const summary = el('summary', { text: '考えていること' });
    // Only a click on the header is a decision by the operator; the setting
    // opening or closing the block must not count as one.
    summary.addEventListener('click', () => {
      if (details) details.dataset.touched = '1';
    });
    details.append(summary, el('div', { class: 'thinkBody' }));
    const answer = box.querySelector('.msg.bot');
    if (answer) box.insertBefore(details, answer);
    else box.append(details);
  }
  details.open = details.dataset.touched === '1' ? details.open : thinkingOpenByDefault();
  const body = details.querySelector('.thinkBody');
  if (body) body.textContent = thinking;
}

function activityLine(turn: Turn): HTMLElement {
  const line = el('div', { class: 'activity' });
  line.dataset.startedAt = String(turn.startedAt || Math.floor(Date.now() / 1000));
  line.append(
    el('span', { class: 'spin', text: SPINNER[0] ?? '' }),
    el('span', { class: 'activityLabel', text: '作業しています…' }),
    el('span', { class: 'elapsed' })
  );
  tickActivity(line);
  return line;
}

function tickActivity(line: HTMLElement): void {
  const started = Number(line.dataset.startedAt) || Math.floor(Date.now() / 1000);
  const seconds = Math.max(0, Math.floor(Date.now() / 1000) - started);
  const mark = line.querySelector('.spin');
  if (mark) mark.textContent = SPINNER[spinFrame % SPINNER.length] ?? '';
  const elapsed = line.querySelector('.elapsed');
  if (elapsed) {
    elapsed.textContent =
      seconds < 60 ? `${seconds}秒` : `${Math.floor(seconds / 60)}分${seconds % 60}秒`;
  }
}

function failureLine(turn: Turn): HTMLElement {
  return el(
    'div',
    { class: 'notice error' },
    el('span', { text: `うまくいきませんでした: ${turn.error || 'unknown'}` })
  );
}

function answerActions(turn: Turn): HTMLElement {
  const copy = el('button', {
    class: 'msgAction',
    type: 'button',
    title: 'コピー',
    'aria-label': '回答をコピー',
  });
  copy.append(icon('copy', 16));
  copy.addEventListener('click', async () => {
    const { answer } = splitOutput(turn.output);
    const ok = await copyText(answer);
    toast(ok ? 'コピーしました' : 'コピーできませんでした', ok ? undefined : 'error');
  });
  const retry = el('button', {
    class: 'msgAction',
    type: 'button',
    title: 'もう一度',
    'aria-label': '同じ依頼をもう一度送る',
  });
  retry.append(icon('retry', 16));
  retry.addEventListener('click', () => {
    void sendPrompt(turn.prompt);
  });
  return el('div', { class: 'msgActions' }, copy, retry);
}

function answerBody(turn: Turn): HTMLElement {
  const prose = el('div', { class: 'prose' });
  prose.append(renderMarkdown(splitOutput(turn.output).answer));
  return prose;
}

function renderTurn(turn: Turn): HTMLElement {
  const box = el('article', { class: 'turn' });
  box.dataset.id = turn.id;
  box.dataset.status = turn.status;
  box.dataset.output = turn.output;

  const answer = el('div', { class: 'msg bot' }, answerBody(turn));
  const user = el('div', { class: 'msg user' }, el('div', { class: 'bubble' }, turn.prompt));
  box.append(user, answer);
  renderThinking(box, splitOutput(turn.output).thinking);
  paintTail(box, turn);
  boxes.set(turn.id, box);
  return box;
}

function paintTail(box: HTMLElement, turn: Turn): void {
  box.querySelector('.activity')?.remove();
  box.querySelector('.notice')?.remove();
  if (turn.status === 'running') box.append(activityLine(turn));
  if (turn.status === 'failed') box.append(failureLine(turn));
  const bot = box.querySelector('.msg.bot');
  if (bot && turn.status !== 'running') {
    if (!bot.querySelector('.msgActions')) bot.append(answerActions(turn));
  }
}

function updateTurn(box: HTMLElement, turn: Turn): void {
  const statusChanged = box.dataset.status !== turn.status;
  const outputChanged = box.dataset.output !== turn.output;
  if (outputChanged) {
    const body = box.querySelector('.prose');
    if (body) {
      const keep = isNearBottom();
      body.replaceChildren(renderMarkdown(splitOutput(turn.output).answer));
      renderThinking(box, splitOutput(turn.output).thinking);
      if (keep) scrollToBottom();
    }
    box.dataset.output = turn.output;
  }
  if (statusChanged) {
    box.dataset.status = turn.status;
    paintTail(box, turn);
    if (turn.status === 'running') renderThinking(box, splitOutput(turn.output).thinking);
  }
}

function isNearBottom(): boolean {
  if (!viewport) return true;
  return viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 96;
}

function scrollToBottom(): void {
  if (!viewport) return;
  viewport.scrollTop = viewport.scrollHeight;
  requestAnimationFrame(() => {
    if (viewport) viewport.scrollTop = viewport.scrollHeight;
  });
}

function emptyState(): HTMLElement {
  const avatar = koalaHtml(state.avatars[state.current], 'idle', 0, 'avatar hero');
  const wrap = el('div', { class: 'empty' });
  wrap.innerHTML = avatar;
  wrap.append(
    el('h1', { class: 'emptyTitle', text: `${state.current} に話しかける` }),
    el('p', {
      class: 'emptyLead',
      text: '頼んだことはこの Bot の会話に残ります。決まった時刻に動かすならルーティンを足せます。',
    })
  );
  const chips = el('div', { class: 'chips' });
  for (const text of [
    'この Bot にできることを教えて',
    '昨日の作業をまとめて',
    '毎朝9時に変更点を要約するルーティンを提案して',
  ]) {
    const chip = el('button', { class: 'chip', type: 'button', text });
    chip.addEventListener('click', () => {
      setComposerText(text);
      input?.focus();
    });
    chips.append(chip);
  }
  wrap.append(chips);
  return wrap;
}

function paintEmptyState(): void {
  if (!thread) return;
  thread.querySelector('.empty')?.remove();
  if (boxes.size === 0 && state.current && !isArchived()) thread.append(emptyState());
}

function isArchived(): boolean {
  return state.archived.includes(state.current);
}

export function resetThread(): void {
  boxes.clear();
  state.turns = [];
  state.cursor = 0;
  if (!thread) return;
  thread.replaceChildren();
  paintEmptyState();
  paintStatusPill();
}

export function refreshComposer(): void {
  setComposerState();
}

export function setComposerText(value: string): void {
  if (!input) return;
  input.value = value;
  autoGrow();
  // A suggestion chip fills the field without an `input` event, so enable the
  // send button here too; typing is not the only way text arrives.
  setComposerState();
}

function autoGrow(): void {
  if (!input) return;
  input.style.height = 'auto';
  input.style.height = `${Math.min(200, Math.max(48, input.scrollHeight))}px`;
}

function setComposerState(): void {
  if (!composer || !input || !sendButton) return;
  const blocked = !state.signedIn || !state.current || isArchived();
  input.disabled = blocked;
  sendButton.disabled = blocked || state.sending || input.value.trim() === '';
  composer.dataset.busy = state.sending ? '1' : '0';
  composer.dataset.blocked = blocked ? '1' : '0';
  if (blocked) {
    input.placeholder = state.signedIn
      ? 'アーカイブした Bot には送れません。戻すと使えます。'
      : 'サインインしてください';
  } else {
    input.placeholder = '回答を入力するか、別の話題について話してください';
  }
}

export function presenceOf(botID: string): { label: string; mood: Mood } {
  if (state.archived.includes(botID)) return { label: 'アーカイブ', mood: 'paused' };
  if (botID === state.current && state.turns.some((turn) => turn.status === 'running')) {
    return { label: '作業中', mood: 'working' };
  }
  const space = state.spaceStates[botID];
  if (space?.state === 'pending') return { label: '準備中', mood: 'thinking' };
  if (space?.state === 'failed') return { label: '準備に失敗', mood: 'error' };
  return { label: '待機中', mood: 'idle' };
}

export function paintStatusPill(): void {
  const name = document.getElementById('statusName');
  const face = document.getElementById('statusFace');
  const presence = document.getElementById('statusPresence');
  const pill = document.getElementById('statusPill');
  if (!name || !face || !presence || !pill) return;
  if (!state.current) {
    name.textContent = 'Bot を選んでください';
    presence.textContent = '';
    face.replaceChildren();
    return;
  }
  const { label, mood } = presenceOf(state.current);
  name.textContent = state.current;
  presence.textContent = label;
  face.innerHTML = koalaHtml(state.avatars[state.current], mood, 0, 'avatar pill');
  pill.dataset.mood = mood;
}

export function paintQuickStatus(): void {
  document.querySelectorAll<HTMLElement>('.botRow').forEach((row) => {
    const botID = row.dataset.bot ?? '';
    const dot = row.querySelector('.botDot');
    if (!dot) return;
    const { mood } = presenceOf(botID);
    (dot as HTMLElement).dataset.mood = mood;
  });
  paintStatusPill();
}

async function poll(): Promise<void> {
  if (!state.signedIn || !state.current || document.hidden || !thread) return;
  const botID = state.current;
  try {
    const payload = await api.turns(botID, state.cursor);
    if (botID !== state.current) return;
    state.cursor = payload.next ?? state.cursor;
    const keep = isNearBottom();
    for (const turn of payload.turns) {
      const existing = boxes.get(turn.id);
      if (existing) updateTurn(existing, turn);
      else thread.append(renderTurn(turn));
      if (!state.turns.some((item) => item.id === turn.id)) state.turns.push(turn);
      else state.turns = state.turns.map((item) => (item.id === turn.id ? turn : item));
      if (turn.prompt) rememberPrompt(botID, turn.prompt);
    }
    if (keep) scrollToBottom();
    paintEmptyState();
    paintStatusPill();
    paintQuickStatus();
  } catch (error) {
    if (error instanceof ApiError && error.status === 401) {
      actions.signedOut();
      return;
    }
    if (error instanceof ApiError && error.status === 429) {
      const presence = document.getElementById('statusPresence');
      if (presence) presence.textContent = '混み合っています';
    }
  }
}

export async function pollNow(): Promise<void> {
  await poll();
}

export async function sendPrompt(text: string): Promise<void> {
  const body = text.trim();
  if (!state.signedIn || !state.current || !body) return;
  if (isArchived()) {
    toast('アーカイブした Bot には送れません', 'error');
    return;
  }
  state.sending = true;
  setComposerState();
  try {
    const res = await api.send(state.current, body);
    if (res.status === 401) {
      actions.signedOut();
      return;
    }
    if (res.status === 429) {
      toast('この Bot は実行中です。終わるまで待ってください。', 'error');
      return;
    }
    if (!res.ok) {
      toast(`送信できません: ${await res.text()}`, 'error');
      return;
    }
    setComposerText('');
    await poll();
    scrollToBottom();
  } catch {
    toast('送信できませんでした。接続を確認してください。', 'error');
  } finally {
    state.sending = false;
    setComposerState();
  }
}

export function initChat(): void {
  thread = document.getElementById('thread');
  viewport = document.getElementById('viewport');
  composer = document.getElementById('composer') as HTMLFormElement | null;
  input = document.getElementById('composerText') as HTMLTextAreaElement | null;
  sendButton = document.getElementById('send') as HTMLButtonElement | null;
  if (!thread || !viewport || !composer || !input || !sendButton) return;

  composer.addEventListener('submit', (event) => {
    event.preventDefault();
    void sendPrompt(input?.value ?? '');
  });
  input.addEventListener('input', () => {
    autoGrow();
    setComposerState();
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      void sendPrompt(input?.value ?? '');
    }
  });

  document.getElementById('statusPill')?.addEventListener('click', () => {
    actions.togglePanel('details');
  });

  input.focus();
  setComposerState();
  paintStatusPill();

  window.setInterval(() => {
    spinFrame += 1;
    document.querySelectorAll<HTMLElement>('.activity').forEach(tickActivity);
    document.querySelectorAll<SVGSVGElement>('svg.avatar[data-anim="1"]').forEach((svg) => {
      let avatar;
      try {
        avatar = JSON.parse(svg.dataset.avatar ?? '{}');
      } catch {
        return;
      }
      const mood = (svg.dataset.mood ?? 'idle') as Mood;
      svg.outerHTML = koalaHtml(
        avatar,
        mood,
        performance.now() / 1000,
        svg.getAttribute('class') ?? 'avatar'
      );
    });
  }, 160);

  timer = window.setInterval(() => {
    void poll();
  }, 2000);
}

export function resetPolling(): void {
  window.clearInterval(timer);
  timer = window.setInterval(() => {
    void poll();
  }, 2000);
}

export function thinkingSetting(): boolean {
  const value = preference(PREF.thinking);
  return value === null ? true : value === '1';
}

export function setThinkingSetting(open: boolean): void {
  setPreference(PREF.thinking, open ? '1' : '0');
  document.querySelectorAll<HTMLDetailsElement>('.think').forEach((details) => {
    delete details.dataset.touched;
    details.open = open;
  });
}

export function relativeOrDash(unix: number): string {
  return unix ? fmtRelative(unix) : '-';
}

export type { TurnStatus };