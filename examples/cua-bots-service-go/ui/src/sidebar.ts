// The left rail: quick access, Bots grouped by the Space they run in, and the
// account chip. Grok Bot groups Bots into named sections; here a Bot's Space is
// the honest grouping, because it is also where the work actually runs.

import type { Avatar } from './api';
import { koalaHtml } from './avatar';
import { actions } from './deps';
import { clear, el, icon } from './dom';
import { PREF, preference, setPreference, spaceLabel, state, type RailSort } from './store';
import { setTheme } from './theme';

function subtitleOf(botID: string): string {
  const last = state.lastPrompts[botID];
  if (last) return last;
  const space = state.botSpaces[botID];
  return space ? spaceLabel(space) : 'Space 未設定';
}

export function botRow(
  botID: string,
  options: { archived?: boolean; badge?: string } = {}
): HTMLElement {
  const avatar = state.avatars[botID];
  const row = el('button', {
    class: 'botRow',
    type: 'button',
    dataset: { bot: botID },
    'aria-current': String(botID === state.current),
  });
  if (options.archived) row.dataset.archived = '1';

  const face = el('span', { class: 'botFace' });
  face.innerHTML = koalaHtml(avatar, 'idle', 0, 'avatar row');
  const meta = el(
    'span',
    { class: 'botMeta' },
    el('span', { class: 'botName', text: botID }),
    el('span', { class: 'botSub', text: subtitleOf(botID) })
  );
  row.append(face, meta);

  if (options.badge) row.append(el('span', { class: 'botBadge', text: options.badge }));
  else {
    const dot = el('span', { class: 'botDot' });
    dot.dataset.mood = 'idle';
    row.append(dot);
  }

  row.addEventListener('click', () => actions.selectBot(botID));
  return row;
}

// The large icons at the top are the Bots the operator pinned, in pin order.
// They used to be "recently opened", which showed arbitrary Bots with no label
// and read as noise.
function quickAccess(): HTMLElement | null {
  const bots = state.pinned.filter((botID) => state.bots.includes(botID));
  if (bots.length === 0) return null;
  const wrap = el('section', { class: 'quickAccess', 'aria-label': 'ピン留めした Bot' });
  wrap.append(el('h2', { class: 'sectionTitle quickTitle', text: 'ピン留め' }));
  const row = el('div', { class: 'quickRow' });
  for (const botID of bots) {
    const item = el('button', {
      class: 'quickItem',
      type: 'button',
      title: `${botID} を開く`,
      'aria-label': `${botID} を開く`,
    });
    const face = el('span', { class: 'quickFace' });
    face.innerHTML = koalaHtml(state.avatars[botID], 'idle', 0, 'avatar quick');
    item.append(face, el('span', { class: 'quickName', text: botID }));
    item.addEventListener('click', () => actions.selectBot(botID));
    row.append(item);
  }
  wrap.append(row);
  return wrap;
}

interface Section {
  key: string;
  label: string;
  bots: string[];
  /** A single list, not a Space group: no count beside the heading. */
  flat?: boolean;
}

/** The order the rail is using now; the picker and the list read the same value. */
export function railSort(): RailSort {
  const saved = preference(PREF.railSort);
  return saved === 'name' || saved === 'recent' ? saved : 'space';
}

function byName(left: string, right: string): number {
  return left.localeCompare(right, 'ja');
}

// The newest turn wins. Bots that have never run go last, in name order.
function byRecent(left: string, right: string): number {
  const a = state.botActivity[left] ?? 0;
  const b = state.botActivity[right] ?? 0;
  if (a !== b) return b - a;
  return byName(left, right);
}

function ordered(bots: string[]): string[] {
  const mode = railSort();
  return [...bots].sort(mode === 'recent' ? byRecent : byName);
}

function sections(): Section[] {
  const mode = railSort();
  if (mode !== 'space') {
    // One flat list. 「最後に動いた順」keeps the useful part of the Space
    // grouping in each row's subtitle instead of in headings.
    return [
      {
        key: mode,
        label: mode === 'recent' ? '最後に動いた順' : '名前順',
        flat: true,
        bots: ordered(state.bots),
      },
    ];
  }
  const groups = new Map<string, string[]>();
  for (const botID of state.bots) {
    const space = state.botSpaces[botID] ?? '';
    // Group by the label the operator sees. Several self-made Spaces share the
    // "ローカル" label, and two identical headings would read as a bug.
    const key = space ? spaceLabel(space) : 'unassigned';
    const list = groups.get(key) ?? [];
    list.push(botID);
    groups.set(key, list);
  }
  const result: Section[] = [];
  for (const [key, bots] of groups) {
    result.push({
      key,
      label: key === 'unassigned' ? '未割り当て' : key,
      bots: bots.sort(byName),
    });
  }
  result.sort((left, right) => {
    if (left.key === 'unassigned') return 1;
    if (right.key === 'unassigned') return -1;
    return left.label.localeCompare(right.label, 'ja');
  });
  return result;
}

export function renderSidebar(): void {
  const quickSlot = document.getElementById('quickAccess');
  if (quickSlot) {
    clear(quickSlot);
    const quick = quickAccess();
    if (quick) quickSlot.append(quick);
    quickSlot.hidden = quick === null;
  }

  const list = document.getElementById('botSections');
  if (!list) return;
  clear(list);

  if (!state.signedIn) {
    list.append(el('p', { class: 'sideNote', text: 'サインインすると Bot が並びます。' }));
    return;
  }
  if (state.bots.length === 0 && state.archived.length === 0) {
    list.append(
      el('p', { class: 'sideNote', text: 'まだ Bot がいません。右上の ＋ から作れます。' })
    );
    return;
  }

  if (state.archived.length > 0) {
    const section = el('section', { class: 'botSection' });
    section.append(el('h2', { class: 'sectionTitle', text: 'アーカイブ' }));
    for (const botID of state.archived) section.append(botRow(botID, { archived: true }));
    list.append(section);
  }

  for (const group of sections()) {
    if (group.bots.length === 0) continue;
    const section = el('section', { class: 'botSection' });
    if (!group.flat) {
      const title = el('h2', { class: 'sectionTitle', text: group.label });
      if (group.key !== 'unassigned')
        title.append(el('span', { class: 'sectionCount', text: String(group.bots.length) }));
      section.append(title);
    }
    for (const botID of group.bots) section.append(botRow(botID));
    list.append(section);
  }
}

export function renderAccount(): void {
  const chip = document.getElementById('accountChip');
  const name = document.getElementById('accountName');
  const face = document.getElementById('accountFace');
  const menu = document.getElementById('accountMenu');
  if (!chip || !name || !face || !menu) return;
  const session = state.session;
  if (!state.signedIn || !session) {
    name.textContent = 'サインインしていません';
    face.textContent = '—';
    chip.setAttribute('aria-disabled', 'true');
    return;
  }
  name.textContent = session.role === 'administrator' ? '管理者' : session.botID || 'Bot';
  face.textContent = (session.role === 'administrator' ? '管' : session.botID || 'B').slice(0, 1);
  chip.removeAttribute('aria-disabled');
}

function setMenu(open: boolean): void {
  const menu = document.getElementById('accountMenu');
  const chip = document.getElementById('accountChip');
  if (!menu || !chip) return;
  menu.hidden = !open;
  chip.setAttribute('aria-expanded', String(open));
}

export function avatarOf(botID: string): Avatar | undefined {
  return state.avatars[botID];
}

export function initSidebar(): void {
  document.getElementById('openSearch')?.addEventListener('click', () => actions.openSearch());
  document.getElementById('openNewBot')?.addEventListener('click', () => actions.openNewBot());

  const sort = document.getElementById('railSort') as HTMLSelectElement | null;
  if (sort) {
    sort.value = railSort();
    sort.addEventListener('change', () => {
      setPreference(PREF.railSort, sort.value);
      renderSidebar();
    });
  }

  const chip = document.getElementById('accountChip');
  chip?.addEventListener('click', () => {
    const menu = document.getElementById('accountMenu');
    setMenu(menu?.hidden ?? true);
  });

  document.getElementById('accountMenu')?.addEventListener('click', (event) => {
    const target = event.target as HTMLElement;
    const action = target.closest<HTMLButtonElement>('[data-action]')?.dataset.action;
    setMenu(false);
    if (action === 'settings') actions.openSettings();
    if (action === 'session') actions.openSettings();
    if (action === 'logout') {
      if (window.confirm('このブラウザから鍵を消します。よろしいですか？')) {
        window.location.href = '/ui?logout=1';
      }
    }
  });

  document.addEventListener('click', (event) => {
    const target = event.target as Node;
    if (!document.getElementById('accountChip')?.contains(target)) setMenu(false);
  });

  document.getElementById('openSidebar')?.addEventListener('click', () => {
    document.body.classList.toggle('sidebarOpen');
  });

  // The sidebar is a drawer on narrow screens; picking a Bot closes it.
  document.getElementById('botSections')?.addEventListener('click', () => {
    document.body.classList.remove('sidebarOpen');
  });

  const theme = document.getElementById('themeSelect') as HTMLSelectElement | null;
  if (theme) {
    theme.value = preference(PREF.theme) ?? 'system';
    theme.addEventListener('change', () => {
      setTheme(theme.value as 'system' | 'light' | 'dark');
    });
  }
}

export function iconButton(name: Parameters<typeof icon>[0], label: string): HTMLButtonElement {
  const button = el('button', {
    class: 'iconButton',
    type: 'button',
    'aria-label': label,
    title: label,
  });
  button.append(icon(name));
  return button;
}