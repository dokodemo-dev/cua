// Dialogs: search, settings, a new Bot, credentials, and the sign-in gate.

import { api, saveCredential, type AgentSettings, type Avatar, type ColorName } from './api';
import { koalaHtml } from './avatar';
import { paintStatusPill, setThinkingSetting, thinkingSetting } from './chat';
import { actions } from './deps';
import { clear, copyText, el, fmtDateTime, icon, toast } from './dom';
import { applyRoute, routeAfterClose, syncRoute, type SettingsSection } from './route';
import {
  COLORS,
  COLOR_NAMES,
  EARS,
  EAR_NAMES,
  EYES,
  EYE_NAMES,
  defaultAvatarFor,
  state,
} from './store';
import { effectiveTheme, setTheme, themePreference } from './theme';

const SHAPE_PAIRS: { ears: (typeof EARS)[number]; eyes: (typeof EYES)[number] }[] = [];
for (const ears of EARS) for (const eyes of EYES) SHAPE_PAIRS.push({ ears, eyes });

interface NewBotDraft {
  name: string;
  avatar: Avatar | null;
  touched: boolean;
}

const draft: NewBotDraft = { name: '', avatar: null, touched: false };

function dialog(id: string): HTMLDialogElement | null {
  return document.getElementById(id) as HTMLDialogElement | null;
}

function showDialog(id: string): HTMLDialogElement | null {
  const node = dialog(id);
  if (!node) return null;
  if (!node.open) node.showModal();
  return node;
}

function closeDialog(id: string): void {
  dialog(id)?.close();
}

function avatarForDraft(): Avatar {
  return draft.avatar ?? defaultAvatarFor(draft.name || 'bot');
}

// ---------------------------------------------------------------- credentials

function setCredentialError(message: string): void {
  const box = document.getElementById('credentialError');
  if (!box) return;
  box.textContent = message;
  box.hidden = message === '';
}

export async function openCredential(botID: string): Promise<void> {
  setCredentialError('');
  try {
    const res = await api.mintToken(botID);
    if (!res.ok) {
      setCredentialError(`発行できません: ${serverMessage(await res.text())}`);
      showDialog('credentialDialog');
      return;
    }
    const data = (await res.json()) as { value?: string };
    const value = document.getElementById('credentialValue') as HTMLInputElement | null;
    if (value) value.value = data.value ?? '';
    showDialog('credentialDialog');
    const copy = document.getElementById('copyCredential');
    if (copy) {
      copy.onclick = async () => {
        const ok = await copyText(
          (document.getElementById('credentialValue') as HTMLInputElement).value
        );
        toast(ok ? 'コピーしました' : 'コピーできませんでした', ok ? 'info' : 'error');
      };
    }
  } catch {
    setCredentialError('発行できませんでした。接続を確認してください。');
    showDialog('credentialDialog');
  }
}

// ------------------------------------------------------------------- search

function searchRows(query: string): HTMLElement[] {
  const term = query.trim().toLowerCase();
  const rows: HTMLElement[] = [];
  for (const botID of state.bots) {
    const space = state.botSpaces[botID] ?? '';
    const haystack = `${botID} ${space} ${state.lastPrompts[botID] ?? ''}`.toLowerCase();
    if (term && !haystack.includes(term)) continue;
    const row = el('button', { class: 'searchRow', type: 'button' });
    const face = el('span', { class: 'searchFace' });
    face.innerHTML = koalaHtml(state.avatars[botID], 'idle', 0, 'avatar row');
    row.append(
      face,
      el(
        'span',
        { class: 'searchText' },
        el('span', { class: 'searchName', text: botID }),
        el('span', {
          class: 'searchSub',
          text: state.lastPrompts[botID] ?? (space || 'Space 未設定'),
        })
      ),
      el('span', { class: 'searchBadge', text: `#${rows.length + 1}` })
    );
    row.addEventListener('click', () => {
      closeDialog('searchDialog');
      actions.selectBot(botID);
    });
    rows.push(row);
  }
  return rows;
}

function renderSearch(): void {
  const input = document.getElementById('searchInput') as HTMLInputElement | null;
  const results = document.getElementById('searchResults');
  if (!input || !results) return;
  clear(results);
  const rows = searchRows(input.value);
  if (rows.length === 0) {
    results.append(el('p', { class: 'panelNote', text: '見つかりませんでした。' }));
    return;
  }
  for (const row of rows) results.append(row);
  (results.firstElementChild as HTMLElement | null)?.classList.add('focused');
}

export function openSearch(): void {
  const node = showDialog('searchDialog');
  if (!node) return;
  const input = document.getElementById('searchInput') as HTMLInputElement | null;
  if (input) {
    input.value = '';
    renderSearch();
    input.focus();
  }
}

// ----------------------------------------------------------------- settings

function settingsGeneral(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  const theme = el(
    'select',
    {},
    el('option', { value: 'system', text: 'システム設定に合わせる' }),
    el('option', { value: 'light', text: 'ライト' }),
    el('option', { value: 'dark', text: 'ダーク' })
  );
  theme.value = themePreference();
  theme.addEventListener('change', () => {
    setTheme(theme.value as 'system' | 'light' | 'dark');
  });
  wrap.append(
    el('h2', { text: '一般' }),
    el(
      'div',
      { class: 'settingsCard' },
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: 'テーマ' }),
        theme
      ),
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: 'いまの表示' }),
        el('span', {
          class: 'settingsValue',
          text: effectiveTheme() === 'light' ? 'ライト' : 'ダーク',
        })
      ),
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: 'アクセント' }),
        el('span', { class: 'settingsValue', text: 'Bot の色' })
      ),
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: '言語' }),
        el('span', { class: 'settingsValue', text: '日本語' })
      )
    )
  );
  return wrap;
}

function settingsAccess(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  wrap.append(el('h2', { text: 'この画面へのアクセス' }));
  wrap.append(
    el('p', {
      class: 'panelNote',
      text: 'Cua のアカウントではありません。このサービスの画面を、このブラウザから操作してよいかを示す鍵です。',
    })
  );
  const session = state.session;
  if (!session) {
    wrap.append(el('p', { class: 'panelNote', text: '接続情報を読めませんでした。' }));
  } else {
    const card = el('div', { class: 'settingsCard' });
    card.append(
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: '種類' }),
        el('span', {
          class: 'settingsValue',
          text:
            session.role === 'administrator'
              ? '管理者（すべての Bot を操作）'
              : `Bot（${session.botID} のみ）`,
        })
      ),
      el(
        'div',
        { class: 'settingsRow' },
        el('span', { class: 'settingsLabel', text: 'できること' }),
        el('span', { class: 'settingsValue', text: (session.capabilities ?? []).join(', ') || '-' })
      )
    );
    if (session.expiresAt) {
      card.append(
        el(
          'div',
          { class: 'settingsRow' },
          el('span', { class: 'settingsLabel', text: '有効期限' }),
          el('span', { class: 'settingsValue', text: fmtDateTime(session.expiresAt) })
        )
      );
    }
    wrap.append(card);
  }
  const signOut = el('button', { class: 'ghost', type: 'button' });
  signOut.append(icon('logout', 16), el('span', { text: 'このブラウザから鍵を消す' }));
  signOut.addEventListener('click', () => {
    if (window.confirm('このブラウザから鍵を消します。よろしいですか？')) {
      window.location.href = '/ui?logout=1';
    }
  });
  wrap.append(
    signOut,
    el('p', { class: 'panelNote muted', text: '消したあとは cua-bots-open で入り直します。' })
  );
  return wrap;
}

// Provider keys the Web UI stores. The service writes them to one 0600 file
// that cua-bot-turn reads, so a key can be added without an SSH session. A
// value in turn.env still wins, and this screen never shows a saved value.
function settingsKeys(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  wrap.append(
    el('h2', { text: 'API キー' }),
    el('p', {
      class: 'panelNote',
      text: 'モデルのプロバイダに渡す鍵です。保存した値は画面に出しません。エージェント設定の「鍵の変数名」にここで保存した名前を書くと、その Bot のターンで使われます。',
    })
  );

  const status = el('p', { class: 'panelNote muted', text: '読み込み中…' });
  const list = el('div', { class: 'settingsCard' });
  wrap.append(status, list);

  const form = el('div', { class: 'settingsCard' });
  const nameField = el('input', {
    type: 'text',
    placeholder: 'OLLAMA_API_KEY',
    autocomplete: 'off',
    'aria-label': '鍵の変数名',
  });
  const valueField = el('input', {
    type: 'password',
    placeholder: 'キーの値（保存後は表示されません）',
    autocomplete: 'off',
    'aria-label': 'キーの値',
  });
  const save = el('button', { class: 'primary', type: 'button', text: '保存' });
  const error = el('p', { class: 'formError', role: 'alert' });
  error.hidden = true;
  const row = el('div', { class: 'keyForm' });
  row.append(nameField, valueField, save);
  form.append(row, error);
  wrap.append(form);

  const fail = (message: string): void => {
    error.textContent = message;
    error.hidden = message === '';
  };

  const refresh = async (): Promise<void> => {
    clear(list);
    try {
      const payload = await api.keys();
      if (!payload.stored) {
        status.textContent = 'このサービスでは鍵の保存先が設定されていません。';
        list.hidden = true;
        return;
      }
      status.textContent =
        payload.keys.length === 0
          ? 'まだ保存された鍵はありません。'
          : '保存済み（値は表示されません）';
      list.hidden = payload.keys.length === 0;
      for (const key of payload.keys) {
        const line = el('div', { class: 'settingsRow' });
        line.append(
          el('span', { class: 'settingsLabel', text: key.name }),
          el('span', { class: 'settingsValue', text: key.last4 })
        );
        const remove = el('button', { class: 'ghost compact', type: 'button', text: '削除' });
        remove.addEventListener('click', async () => {
          if (!window.confirm(`${key.name} を削除します。よろしいですか？`)) return;
          const res = await api.removeKey(key.name);
          if (!res.ok) fail(`削除できません: ${serverMessage(await res.text())}`);
          else await refresh();
        });
        line.append(remove);
        list.append(line);
      }
    } catch {
      status.textContent = '鍵の一覧を読めませんでした。';
    }
  };

  save.addEventListener('click', async () => {
    const name = nameField.value.trim().toUpperCase();
    const value = valueField.value.trim();
    if (!name || !value) {
      fail('変数名とキーの値を入れてください。');
      return;
    }
    save.disabled = true;
    try {
      const res = await api.setKey(name, value);
      if (!res.ok) {
        fail(`保存できません: ${serverMessage(await res.text())}`);
        return;
      }
      fail('');
      nameField.value = '';
      valueField.value = '';
      await refresh();
    } catch {
      fail('保存できませんでした。接続を確認してください。');
    } finally {
      save.disabled = false;
    }
  });

  void refresh();
  return wrap;
}

// The clipboard API is unavailable over plain HTTP (the VPN address), so the
// command is shown selected in a dialog: ⌘C works even when no copy API does.
function openCommand(command: string): void {
  const field = document.getElementById('commandText') as HTMLInputElement | null;
  const copy = document.getElementById('commandCopy') as HTMLButtonElement | null;
  if (!field || !copy) return;
  field.value = command;
  copy.onclick = async () => {
    const ok = await copyText(command);
    if (ok) {
      toast('コピーしました');
      return;
    }
    field.focus();
    field.select();
    toast('コピーできませんでした。選択して ⌘C でどうぞ', 'error');
  };
  showDialog('commandDialog');
  field.focus();
  field.select();
}

// Every Space the host lists, plus any a Bot still points at, with the Bots in
// it. Read-only: creating or moving a Space stays a CLI job.
function settingsSpaces(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  wrap.append(
    el('h2', { text: 'Space' }),
    el('p', {
      class: 'panelNote',
      text: 'Bot が実際に動く場所です。作成・移動は CLI（cua spaces / cua sb）で行います。',
    })
  );

  const status = el('p', { class: 'panelNote muted', text: '読み込み中…' });
  const list = el('div', { class: 'settingsCard' });
  wrap.append(status, list);

  const render = (): void => {
    clear(list);
    // The Bot → Space map is already loaded with the rail, so the section works
    // even when the host's Space list cannot be read.
    const usage = new Map<string, string[]>();
    for (const [botID, spaceID] of Object.entries(state.botSpaces)) {
      if (!spaceID) continue;
      const bots = usage.get(spaceID) ?? [];
      bots.push(botID);
      usage.set(spaceID, bots);
    }
    const known = new Map(state.spaces.map((space) => [space.id, space]));
    const ids = new Set([...known.keys(), ...usage.keys()]);
    if (ids.size === 0) {
      list.append(el('p', { class: 'panelNote', text: 'まだ Space がありません。' }));
      return;
    }
    for (const id of [...ids].sort((a, b) => a.localeCompare(b))) {
      const info = known.get(id);
      const bots = (info?.bots ?? usage.get(id) ?? [])
        .slice()
        .sort((a, b) => a.localeCompare(b, 'ja'));
      const registered = info ? info.registered !== false : false;
      const row = el('div', { class: 'spaceRow' });
      const head = el('button', {
        class: 'spaceHead',
        type: 'button',
        'aria-expanded': 'false',
      });
      const name = el('span', { class: 'spaceName' });
      name.append(
        el('span', { class: 'settingsLabel', text: info?.name || id }),
        el('code', { class: 'spaceID', text: id })
      );
      const right = el('span', { class: 'spaceMeta' });
      if (!registered) right.append(el('span', { class: 'spaceBadge warn', text: 'cua 未登録' }));
      if (info?.state && info.state !== 'ready') {
        right.append(el('span', { class: 'spaceBadge', text: info.state }));
      }
      right.append(el('span', { class: 'settingsValue', text: `${bots.length} 台` }));
      head.append(name, right);

      const detail = el('div', { class: 'spaceBots' });
      detail.hidden = true;
      if (bots.length === 0) {
        detail.append(
          el('p', { class: 'panelNote muted', text: 'この Space を使う Bot はありません。' })
        );
      } else {
        for (const botID of bots) {
          detail.append(el('span', { class: 'spaceBot', text: botID }));
        }
      }
      const copy = el('button', {
        class: 'ghost compact',
        type: 'button',
        text: '接続コマンドを表示',
      });
      copy.addEventListener('click', () => openCommand(`cua sb shell ${id}`));
      detail.append(copy);

      head.addEventListener('click', () => {
        const open = head.getAttribute('aria-expanded') !== 'true';
        head.setAttribute('aria-expanded', String(open));
        detail.hidden = !open;
      });
      row.append(head, detail);
      list.append(row);
    }
  };

  render();
  void (async () => {
    if (state.spaces.length === 0) {
      try {
        const payload = await api.spaces();
        if ((payload.spaces ?? []).length > 0) state.spaces = payload.spaces ?? [];
        state.spacesNote = payload.note ?? '';
      } catch {
        state.spacesNote = 'Space の一覧を取得できませんでした';
      }
    }
    status.textContent = state.spacesNote || '作成・移動は CLI で行います。';
    render();
  })();
  return wrap;
}

function settingsChat(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  wrap.append(el('h2', { text: '会話の表示' }));
  const card = el('div', { class: 'settingsCard' });
  const label = el('label', { class: 'settingsToggle' });
  const checkbox = el('input', { type: 'checkbox' });
  checkbox.checked = thinkingSetting();
  checkbox.addEventListener('change', () => {
    setThinkingSetting(checkbox.checked);
  });
  label.append(
    checkbox,
    el(
      'span',
      {},
      el('span', { text: '考えていることを最初から開いて表示する' }),
      el('span', {
        class: 'settingsHint',
        text: '切ると閉じた状態で出ます。見出しをクリックすれば開閉できます。',
      })
    )
  );
  card.append(label);
  wrap.append(
    card,
    el('p', { class: 'panelNote muted', text: 'この設定はこのブラウザにだけ保存されます。' })
  );
  return wrap;
}

function settingsScreen(): HTMLElement {
  const wrap = el('div', { class: 'settingsPane' });
  wrap.append(
    el('h2', { text: '画面' }),
    el('p', {
      class: 'panelNote',
      text: 'Bot のデスクトップは SSH トンネル越しに開きます。ターミナルで次を実行してください。',
    }),
    el('code', { class: 'codeLine', text: 'cua-view' })
  );
  return wrap;
}

function renderSettings(section: SettingsSection): void {
  const body = document.getElementById('settingsBody');
  if (!body) return;
  document.querySelectorAll<HTMLButtonElement>('#settingsNav button').forEach((button) => {
    button.setAttribute('aria-selected', String(button.dataset.section === section));
  });
  clear(body);
  if (section === 'general') body.append(settingsGeneral());
  else if (section === 'access') body.append(settingsAccess());
  else if (section === 'spaces') body.append(settingsSpaces());
  else if (section === 'keys') body.append(settingsKeys());
  else if (section === 'chat') body.append(settingsChat());
  else body.append(settingsScreen());
}

export function openSettings(section: SettingsSection = 'general'): void {
  showDialog('settingsDialog');
  renderSettings(section);
  syncRoute();
  void refreshSession();
}

/** Closes the dialog; its close handler decides where history goes. */
export function closeSettings(): void {
  closeDialog('settingsDialog');
}

async function refreshSession(): Promise<void> {
  if (!state.signedIn) return;
  try {
    state.session = await api.session();
    if (document.getElementById('settingsDialog')?.hasAttribute('open')) {
      const active = document.querySelector<HTMLButtonElement>(
        '#settingsNav [aria-selected="true"]'
      );
      renderSettings((active?.dataset.section ?? 'general') as SettingsSection);
    }
  } catch {
    // Leave the last known facts on screen.
  }
}

// ----------------------------------------------------------------- new bot

// The service accepts 1-63 of a-z, 0-9, dot, underscore or hyphen (the Volume
// rule). Say so before the request, instead of turning it into a server error.
const NAME_PATTERN = /^[a-z0-9._-]{1,63}$/;

function nameProblem(name: string): string {
  const value = name.trim();
  if (!value) return '名前を入れてください。';
  if (!NAME_PATTERN.test(value)) {
    return '名前に使えるのは半角小文字の英数字と . _ - だけです（63文字まで）。';
  }
  return '';
}

function setNewBotError(message: string): void {
  const box = document.getElementById('newBotError');
  if (!box) return;
  box.textContent = message;
  box.hidden = message === '';
}

function serverMessage(body: string): string {
  try {
    const parsed = JSON.parse(body) as { error?: string };
    if (parsed.error) return parsed.error;
  } catch {
    // Not JSON; show the body as-is.
  }
  return body;
}

function renderShapeGrid(
  container: HTMLElement,
  avatar: Avatar,
  onPick: (next: Avatar) => void
): void {
  clear(container);
  for (const pair of SHAPE_PAIRS) {
    const option = { ...avatar, ears: pair.ears, eyes: pair.eyes };
    const button = el('button', {
      class: 'shapePick',
      type: 'button',
      'aria-label': `${EAR_NAMES[pair.ears]}の耳・${EYE_NAMES[pair.eyes]}の目`,
      'aria-pressed': String(avatar.ears === pair.ears && avatar.eyes === pair.eyes),
    });
    button.innerHTML = koalaHtml(option, 'idle', 0, 'avatar shape');
    button.addEventListener('click', () => onPick(option));
    container.append(button);
  }
}

function renderColorRow(
  container: HTMLElement,
  avatar: Avatar,
  onPick: (color: ColorName) => void
): void {
  clear(container);
  for (const color of COLORS) {
    const button = el('button', {
      class: 'colorPick',
      type: 'button',
      'data-color': color,
      'aria-label': COLOR_NAMES[color],
      title: COLOR_NAMES[color],
      'aria-pressed': String(avatar.color === color),
    });
    button.addEventListener('click', () => onPick(color));
    container.append(button);
  }
}

function paintNewBot(): void {
  const preview = document.getElementById('newBotPreview');
  const name = document.getElementById('newBotName') as HTMLInputElement | null;
  const grid = document.getElementById('shapeGrid');
  const colors = document.getElementById('colorRow');
  const create = document.getElementById('createBot') as HTMLButtonElement | null;
  const hint = document.getElementById('newBotHint');
  if (!preview || !name || !grid || !colors || !create) return;

  const avatar = avatarForDraft();
  preview.innerHTML = koalaHtml(avatar, 'happy', 0, 'avatar hero');
  if (name.value !== draft.name) name.value = draft.name;
  const problem = nameProblem(draft.name);
  create.disabled = problem !== '';
  if (hint) {
    hint.dataset.invalid = draft.name.trim() !== '' && problem !== '' ? '1' : '0';
  }

  renderShapeGrid(grid, avatar, (next) => {
    draft.avatar = { ...avatarForDraft(), ears: next.ears, eyes: next.eyes };
    draft.touched = true;
    paintNewBot();
  });
  renderColorRow(colors, avatar, (color) => {
    draft.avatar = { ...avatarForDraft(), color };
    draft.touched = true;
    paintNewBot();
  });
}

// --------------------------------------------------------------- look dialog

const look: { botID: string; avatar: Avatar } = {
  botID: '',
  avatar: { color: 'sky', eyes: 'star', ears: 'scalloped' },
};

function setAvatarError(message: string): void {
  const box = document.getElementById('avatarError');
  if (!box) return;
  box.textContent = message;
  box.hidden = message === '';
}

function paintAvatarDialog(): void {
  const preview = document.getElementById('avatarPreview');
  const shapes = document.getElementById('avatarShapes');
  const colors = document.getElementById('avatarColors');
  if (!preview || !shapes || !colors) return;
  preview.innerHTML = koalaHtml(look.avatar, 'happy', 0, 'avatar hero');
  renderShapeGrid(shapes, look.avatar, (next) => {
    look.avatar = next;
    paintAvatarDialog();
  });
  renderColorRow(colors, look.avatar, (color) => {
    look.avatar = { ...look.avatar, color };
    paintAvatarDialog();
  });
}

export function openAvatar(botID: string): void {
  look.botID = botID;
  look.avatar = { ...(state.avatars[botID] ?? defaultAvatarFor(botID)) };
  setAvatarError('');
  paintAvatarDialog();
  showDialog('avatarDialog');
}

async function saveAvatar(): Promise<void> {
  const botID = look.botID;
  if (!botID) return;
  const button = document.getElementById('saveAvatar') as HTMLButtonElement | null;
  if (button) button.disabled = true;
  try {
    const res = await api.setAvatar(botID, look.avatar);
    if (!res.ok) {
      setAvatarError(`保存できません: ${serverMessage(await res.text())}`);
      return;
    }
    state.avatars[botID] = look.avatar;
    closeDialog('avatarDialog');
    actions.refreshSidebar();
    actions.refreshPanel();
    paintStatusPill();
  } catch {
    setAvatarError('保存できませんでした。接続を確認してください。');
  } finally {
    if (button) button.disabled = false;
  }
}

function paintSpaceOptions(): void {
  const select = document.getElementById('newBotSpace') as HTMLSelectElement | null;
  if (!select) return;
  const current = select.value;
  clear(select);
  select.append(el('option', { value: '', text: '新しい Space をつくる（おすすめ）' }));
  for (const space of state.spaces) {
    select.append(
      el('option', { value: space.id, text: `${space.name || space.id}（${space.id}）` })
    );
  }
  select.value = state.spaces.some((space) => space.id === current) ? current : '';
}

export async function openNewBot(): Promise<void> {
  draft.name = '';
  draft.avatar = null;
  draft.touched = false;
  setNewBotError('');
  showDialog('newBotDialog');
  if (state.spaces.length === 0) {
    try {
      const payload = await api.spaces();
      const known = payload.spaces ?? [];
      if (known.length > 0) state.spaces = known;
      state.spacesNote = payload.note ?? '';
    } catch {
      // Keep the labels we had; an empty list would regroup the whole rail.
      state.spacesNote = 'Space の一覧を取得できませんでした';
    }
  }
  paintSpaceOptions();
  paintNewBot();
  (document.getElementById('newBotName') as HTMLInputElement | null)?.focus();
}

async function createBot(): Promise<void> {
  const name = draft.name.trim();
  const problem = nameProblem(name);
  if (problem) {
    setNewBotError(problem);
    return;
  }
  setNewBotError('');
  const select = document.getElementById('newBotSpace') as HTMLSelectElement | null;
  const spaceID = select?.value ?? '';
  const createSpace = spaceID === '';
  const button = document.getElementById('createBot') as HTMLButtonElement | null;
  if (button) button.disabled = true;
  try {
    const res = await api.createBot({
      name,
      spaceID: createSpace ? `local:bot-${name}` : spaceID,
      createSpace,
    });
    if (res.status === 401) {
      actions.signedOut();
      return;
    }
    if (!res.ok) {
      const message = serverMessage(await res.text());
      const hint =
        res.status === 403
          ? `${message}（既存の Space には、その Space の信頼グループでしか入れません。新しい Space を作ってください）`
          : message;
      // The dialog is open: show the reason where the action happened instead
      // of a toast that would sit on top of the footer.
      setNewBotError(`つくれませんでした: ${hint}`);
      return;
    }
    await api.setAvatar(name, avatarForDraft()).catch(() => {});
    setNewBotError('');
    closeDialog('newBotDialog');
    await actions.refreshBots();
    actions.selectBot(name);
    if (createSpace) {
      toast(`${name} の Space をつくっています。1〜2分かかります。`);
      void watchSpace(name);
    } else {
      toast(`${name} を ${spaceID} に追加しました。`);
    }
  } catch {
    setNewBotError('つくれませんでした。接続を確認してください。');
  } finally {
    if (button) button.disabled = nameProblem(draft.name) !== '';
  }
}

async function watchSpace(botID: string): Promise<void> {
  for (;;) {
    await new Promise((resolve) => setTimeout(resolve, 3000));
    let space;
    try {
      space = await api.botSpace(botID);
    } catch {
      continue;
    }
    state.spaceStates[botID] = space;
    if (space.state === 'ready') {
      toast(`${botID} の準備ができました。`);
      actions.refreshSidebar();
      return;
    }
    if (space.state === 'failed') {
      toast(`Space の準備に失敗しました: ${space.detail ?? ''}`, 'error');
      return;
    }
  }
}

// ---------------------------------------------------------------- agent

const AGENT_PRESETS = [
  { id: 'inherit', label: '全体設定に従う' },
  { id: 'space', label: 'Space のログイン' },
  { id: 'openai', label: 'OpenAI API' },
  { id: 'anthropic', label: 'Anthropic API' },
  { id: 'openrouter', label: 'OpenRouter' },
  { id: 'deepseek', label: 'DeepSeek' },
  { id: 'ollama', label: 'Ollama Cloud' },
  { id: 'opencode', label: 'OpenCode Go' },
  { id: 'offpeak', label: 'オフピーク自動' },
  { id: 'dsh', label: 'DeepSeek Harness' },
  { id: 'custom', label: 'カスタム' },
];

const HARNESSES = [
  'pi',
  'openai-codex',
  'claude-code',
  'gemini-cli',
  'google-antigravity',
  'opencode',
  'goose',
  'deepseek-harness',
  'hermes',
  'openclaw',
];

// Ollama Cloud is half price outside 12:00-18:00 UTC on weekdays (21:00-03:00
// JST); OpenCode Go's DeepSeek is half price then, so the two cover the day.
const OFFPEAK_SCHEDULE = [
  'mon-fri 21:00-24:00 opencode',
  'tue-sat 00:00-03:00 opencode',
  '* ollama',
].join('\n');

const agentDraft: { botID: string; preset: string } = { botID: '', preset: 'inherit' };

function agentInput(id: string): HTMLInputElement | null {
  return document.getElementById(id) as HTMLInputElement | null;
}

function agentText(id: string): HTMLTextAreaElement | null {
  return document.getElementById(id) as HTMLTextAreaElement | null;
}

function agentSelect(): HTMLSelectElement | null {
  return document.getElementById('agentHarness') as HTMLSelectElement | null;
}

function wireSelect(): HTMLSelectElement | null {
  return document.getElementById('agentWire') as HTMLSelectElement | null;
}

function setAgentError(message: string): void {
  const box = document.getElementById('agentError');
  if (!box) return;
  box.textContent = message;
  box.hidden = message === '';
}

function paintAgent(): void {
  const presets = document.getElementById('agentPresets');
  if (presets) {
    clear(presets);
    for (const preset of AGENT_PRESETS) {
      const button = el('button', {
        class: 'presetChip',
        type: 'button',
        'aria-pressed': String(agentDraft.preset === preset.id),
        text: preset.label,
      });
      button.addEventListener('click', () => {
        agentDraft.preset = preset.id;
        applyPreset(preset.id);
        paintAgent();
      });
      presets.append(button);
    }
  }

  const fields = document.getElementById('agentFields');
  if (fields) fields.hidden = agentDraft.preset === 'inherit';

  const harness = agentSelect();
  if (harness && harness.options.length === 0) {
    for (const name of HARNESSES) harness.append(el('option', { value: name, text: name }));
  }
}

function applyPreset(id: string): void {
  const harness = agentSelect();
  const model = agentInput('agentModel');
  const base = agentInput('agentBase');
  const wire = wireSelect();
  const keys = agentInput('agentKeys');
  const headers = agentInput('agentHeaders');
  const schedule = agentText('agentSchedule');
  if (!harness || !model || !base || !wire || !keys || !headers || !schedule) return;
  headers.value = '';
  schedule.value = '';
  if (id === 'space') {
    harness.value = 'pi';
    model.value = '';
    base.value = '';
    wire.value = '';
    keys.value = '';
  } else if (id === 'openai') {
    harness.value = 'openai-codex';
    model.value = '';
    base.value = '';
    wire.value = '';
    keys.value = 'OPENAI_API_KEY';
  } else if (id === 'anthropic') {
    harness.value = 'claude-code';
    model.value = '';
    base.value = '';
    wire.value = '';
    keys.value = 'ANTHROPIC_API_KEY';
  } else if (id === 'openrouter') {
    harness.value = 'pi';
    model.value = '';
    base.value = 'https://openrouter.ai/api/v1';
    wire.value = 'openai-chat';
    keys.value = 'OPENROUTER_API_KEY';
  } else if (id === 'deepseek') {
    harness.value = 'pi';
    model.value = 'deepseek-chat';
    base.value = 'https://api.deepseek.com/v1';
    wire.value = 'openai-chat';
    keys.value = 'DEEPSEEK_API_KEY';
  } else if (id === 'ollama') {
    harness.value = 'pi';
    model.value = 'deepseek-v4.1-flash:1017';
    base.value = 'https://ollama.com/v1';
    wire.value = 'openai-chat';
    keys.value = 'OLLAMA_API_KEY';
  } else if (id === 'opencode') {
    harness.value = 'pi';
    model.value = 'deepseek-v4.1-flash';
    base.value = 'https://opencode.ai/zen/go/v1';
    wire.value = 'openai-chat';
    keys.value = 'OPENCODE_API_KEY';
    headers.value = 'x-opencode-session=cua-bots';
  } else if (id === 'offpeak') {
    harness.value = 'pi';
    model.value = 'deepseek-v4.1-flash:1017';
    base.value = 'https://ollama.com/v1';
    wire.value = 'openai-chat';
    keys.value = 'OLLAMA_API_KEY';
    headers.value = '';
    schedule.value = OFFPEAK_SCHEDULE;
  } else if (id === 'dsh') {
    harness.value = 'deepseek-harness';
    model.value = '';
    base.value = '';
    wire.value = '';
    keys.value = 'DEEPSEEK_API_KEY';
  }
}

export function openAgent(botID: string): void {
  agentDraft.botID = botID;
  agentDraft.preset = state.agentSet ? state.agent.provider || 'custom' : 'inherit';
  setAgentError('');
  paintAgent();
  const harness = agentSelect();
  if (harness) harness.value = state.agent.harness || 'pi';
  const model = agentInput('agentModel');
  if (model) model.value = state.agent.model ?? '';
  const base = agentInput('agentBase');
  if (base) base.value = state.agent.baseURL ?? '';
  const wire = wireSelect();
  if (wire) wire.value = state.agent.wire ?? '';
  const keys = agentInput('agentKeys');
  if (keys) keys.value = (state.agent.keyVars ?? []).join(', ');
  const headers = agentInput('agentHeaders');
  if (headers) {
    headers.value = Object.entries(state.agent.headers ?? {})
      .map(([name, value]) => `${name}=${value}`)
      .join(', ');
  }
  const schedule = agentText('agentSchedule');
  if (schedule) schedule.value = state.agentSchedule;
  showDialog('agentDialog');
  if (agentDraft.preset === 'inherit') applyPreset('inherit');
}

async function saveAgent(): Promise<void> {
  const botID = agentDraft.botID;
  if (!botID) return;
  const button = document.getElementById('agentSave') as HTMLButtonElement | null;
  if (button) button.disabled = true;
  try {
    let body = {};
    if (agentDraft.preset !== 'inherit') {
      const harness = agentSelect();
      const model = agentInput('agentModel');
      const base = agentInput('agentBase');
      const keys = agentInput('agentKeys');
      const headers = agentInput('agentHeaders');
      const headerPairs = (headers?.value ?? '')
        .split(',')
        .map((pair) => pair.trim())
        .filter((pair) => pair.includes('='));
      const headerMap: Record<string, string> = {};
      for (const pair of headerPairs) {
        const at = pair.indexOf('=');
        headerMap[pair.slice(0, at).trim()] = pair.slice(at + 1).trim();
      }
      body = {
        harness: harness?.value ?? 'pi',
        provider: agentDraft.preset,
        model: model?.value.trim() ?? '',
        baseURL: base?.value.trim() ?? '',
        wire: wireSelect()?.value ?? '',
        keyVars: (keys?.value ?? '')
          .split(',')
          .map((name) => name.trim())
          .filter((name) => name !== ''),
        headers: headerMap,
      };
    }
    const schedule = agentText('agentSchedule');
    const res = await api.setAgent(botID, body, schedule?.value.trim() ?? '');
    if (!res.ok) {
      setAgentError(`保存できません: ${serverMessage(await res.text())}`);
      return;
    }
    const payload = (await res.json()) as { agent?: AgentSettings; set?: boolean };
    state.agent = payload.agent ?? {};
    state.agentSet = Boolean(payload.set);
    closeDialog('agentDialog');
    actions.refreshPanel();
    toast('エージェント設定を保存しました（次のターンから）');
  } catch {
    setAgentError('保存できませんでした。接続を確認してください。');
  } finally {
    if (button) button.disabled = false;
  }
}

// --------------------------------------------------------------- routines

const routineFor: { botID: string } = { botID: '' };

function setRoutineError(message: string): void {
  const box = document.getElementById('routineError');
  if (!box) return;
  box.textContent = message;
  box.hidden = message === '';
}

export function openRoutine(botID: string): void {
  routineFor.botID = botID;
  setRoutineError('');
  const title = document.getElementById('rtTitle') as HTMLInputElement | null;
  const prompt = document.getElementById('rtPrompt') as HTMLTextAreaElement | null;
  const every = document.getElementById('rtEvery') as HTMLSelectElement | null;
  const delay = document.getElementById('rtDelay') as HTMLSelectElement | null;
  if (title) title.value = '';
  if (prompt) prompt.value = '';
  if (every) every.value = '86400';
  if (delay) delay.value = '3600';
  showDialog('routineDialog');
  title?.focus();
}

async function addRoutine(): Promise<void> {
  const botID = routineFor.botID;
  if (!botID) return;
  const title = document.getElementById('rtTitle') as HTMLInputElement | null;
  const prompt = document.getElementById('rtPrompt') as HTMLTextAreaElement | null;
  const every = document.getElementById('rtEvery') as HTMLSelectElement | null;
  const delay = document.getElementById('rtDelay') as HTMLSelectElement | null;
  if (!title || !prompt || !every || !delay) return;
  if (!title.value.trim() || !prompt.value.trim()) {
    setRoutineError('名前と頼むことを入れてください。');
    return;
  }
  const button = document.getElementById('rtAdd') as HTMLButtonElement | null;
  if (button) button.disabled = true;
  try {
    const res = await api.addRoutine(botID, {
      title: title.value.trim(),
      prompt: prompt.value.trim(),
      everySec: Number(every.value),
      delaySec: Number(delay.value),
    });
    if (res.status === 401) {
      actions.signedOut();
      return;
    }
    if (!res.ok) {
      setRoutineError(`追加できません: ${serverMessage(await res.text())}`);
      return;
    }
    closeDialog('routineDialog');
    await actions.loadRoutines();
    toast('ルーティンを追加しました');
  } catch {
    setRoutineError('追加できませんでした。接続を確認してください。');
  } finally {
    if (button) button.disabled = false;
  }
}

// -------------------------------------------------------------------- gate

function initGate(): void {
  const signIn = document.getElementById('gateSignIn');
  const field = document.getElementById('gateCred') as HTMLInputElement | null;
  signIn?.addEventListener('click', async () => {
    const value = field?.value.trim() ?? '';
    if (!value) return;
    saveCredential(value);
    if (field) field.value = '';
    await actions.refreshBots();
    if (state.signedIn) {
      const gate = document.getElementById('gate');
      if (gate) gate.hidden = true;
      actions.refreshSidebar();
      actions.openPanel('details');
    } else {
      toast('この資格情報では入れませんでした。', 'error');
    }
  });
  field?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') signIn?.dispatchEvent(new MouseEvent('click'));
  });
}

function noteLoginFailure(): void {
  if (!location.search.includes('login=failed')) return;
  const hint = document.getElementById('gateHint');
  if (hint) {
    hint.hidden = false;
    hint.textContent =
      'このリンクはもう使えません（資格情報が失効しています）。ターミナルで cua-bots-open を実行し直してください。';
  }
  history.replaceState(null, '', location.pathname);
}

export function initModals(): void {
  document.querySelectorAll<HTMLElement>('[data-close]').forEach((button) => {
    button.addEventListener('click', () => {
      (button.closest('dialog') as HTMLDialogElement | null)?.close();
    });
  });
  // Escape and a backdrop click close a dialog without `data-close`.
  document.querySelectorAll<HTMLDialogElement>('dialog.sheet').forEach((dialog) => {
    dialog.addEventListener('close', () => routeAfterClose());
  });
  window.addEventListener('popstate', () => applyRoute());

  const searchInput = document.getElementById('searchInput') as HTMLInputElement | null;
  searchInput?.addEventListener('input', () => renderSearch());
  searchInput?.addEventListener('keydown', (event) => {
    const results = document.getElementById('searchResults');
    if (!results) return;
    const rows = [...results.querySelectorAll<HTMLElement>('.searchRow')];
    const index = rows.findIndex((row) => row.classList.contains('focused'));
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (rows.length === 0) return;
      const next =
        event.key === 'ArrowDown'
          ? (index + 1) % rows.length
          : (index - 1 + rows.length) % rows.length;
      rows.forEach((row) => row.classList.remove('focused'));
      rows[next]?.classList.add('focused');
      rows[next]?.scrollIntoView({ block: 'nearest' });
    } else if (event.key === 'Enter') {
      event.preventDefault();
      (rows[index] ?? rows[0])?.click();
    }
  });

  document.querySelectorAll<HTMLButtonElement>('#settingsNav button').forEach((button) => {
    button.addEventListener('click', () => {
      renderSettings((button.dataset.section ?? 'general') as SettingsSection);
      // Another section is the same view: replace, so back closes the dialog
      // instead of walking through every section that was looked at.
      syncRoute(true);
    });
  });

  const name = document.getElementById('newBotName') as HTMLInputElement | null;
  name?.addEventListener('input', () => {
    draft.name = name.value;
    if (!draft.touched) draft.avatar = null;
    setNewBotError('');
    paintNewBot();
  });
  name?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      void createBot();
    }
  });
  document.getElementById('createBot')?.addEventListener('click', () => void createBot());
  document.getElementById('saveAvatar')?.addEventListener('click', () => void saveAvatar());
  document.getElementById('rtAdd')?.addEventListener('click', () => void addRoutine());
  document.getElementById('agentSave')?.addEventListener('click', () => void saveAgent());
  const rtTitle = document.getElementById('rtTitle') as HTMLInputElement | null;
  rtTitle?.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      void addRoutine();
    }
  });

  initGate();
  noteLoginFailure();

  document.addEventListener('keydown', (event) => {
    const modifier = event.metaKey || event.ctrlKey;
    if (modifier && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      openSearch();
    } else if (modifier && event.key.toLowerCase() === 'n') {
      event.preventDefault();
      void openNewBot();
    } else if (modifier && event.key === ',') {
      event.preventDefault();
      openSettings();
    }
  });
}