// The right panel: what Grok Bot puts behind the Bot's name — details,
// routines, and the computer the Bot runs on.

import { ApiError, api, type Artifact, type Routine, type SpaceState } from './api';
import { koalaHtml } from './avatar';
import { presenceOf } from './chat';
import { actions } from './deps';
import {
  clear,
  copyText,
  el,
  fmtBytes,
  fmtDateTime,
  fmtInterval,
  fmtRelative,
  icon,
  toast,
} from './dom';
import { openAgent, openAvatar, openCredential, openRoutine } from './modals';
import { syncRoute } from './route';
import { applyPins, isPinned, spaceLabel, state, type PanelTab } from './store';

function currentSpaceState(): SpaceState | null {
  return state.spaceStates[state.current] ?? null;
}

function statePill(botID: string): HTMLElement {
  const { label, mood } = presenceOf(botID);
  return el('span', { class: 'statePill', dataset: { mood }, text: label });
}

function sectionTitle(text: string): HTMLElement {
  return el('h3', { class: 'panelSection', text });
}

function routineCard(job: Routine): HTMLElement {
  const card = el('div', { class: 'routineCard' });
  const text = el(
    'div',
    { class: 'routineText' },
    el('span', { class: 'routineTitle', text: job.title }),
    el('span', {
      class: 'routineWhen',
      text: `${fmtInterval(job.everySec)}ごと・次回 ${job.nextRunAt ? fmtRelative(job.nextRunAt) : '未定'}`,
    })
  );
  const toggle = el('button', {
    class: 'switch',
    type: 'button',
    role: 'switch',
    'aria-checked': String(!job.paused),
    'aria-label': `${job.title} を${job.paused ? '再開' : '停止'}する`,
  });
  toggle.append(el('span', { class: 'switchKnob' }));
  toggle.addEventListener('click', async () => {
    toggle.disabled = true;
    try {
      const res = await api.changeRoutine(state.current, job.id, job.paused ? 'resume' : 'pause');
      if (!res.ok) throw new ApiError(res.status, await res.text());
      await loadRoutines();
    } catch (error) {
      toast(error instanceof ApiError ? error.message : '変更できませんでした', 'error');
      toggle.disabled = false;
    }
  });
  const remove = el('button', {
    class: 'iconButton small',
    type: 'button',
    'aria-label': `${job.title} を削除`,
    title: '削除',
  });
  remove.append(icon('trash', 16));
  remove.addEventListener('click', async () => {
    if (!window.confirm(`「${job.title}」を削除します。よろしいですか？`)) return;
    const res = await api.deleteRoutine(state.current, job.id);
    if (!res.ok) {
      toast(`削除できません: ${await res.text()}`, 'error');
      return;
    }
    await loadRoutines();
  });
  card.append(text, el('div', { class: 'routineControls' }, toggle, remove));
  return card;
}

function routinesSection(): HTMLElement {
  const wrap = el('section', { class: 'panelBlock' });
  const head = el('div', { class: 'panelSectionRow' });
  head.append(sectionTitle('ルーティン'));
  const add = el('button', { class: 'ghost compact', type: 'button' });
  add.append(icon('plus', 14), el('span', { text: '追加' }));
  add.addEventListener('click', () => openRoutine(state.current));
  head.append(add);
  wrap.append(head);

  if (state.routines.length === 0) {
    wrap.append(
      el('p', { class: 'panelNote', text: 'まだありません。決めた時刻に Bot が自分から動きます。' })
    );
  } else {
    const list = el('div', { class: 'routineList' });
    for (const job of state.routines) list.append(routineCard(job));
    wrap.append(list);
  }
  return wrap;
}

/** The time a window ends, as the viewer's clock reads it. */
function untilLabel(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  return at.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' });
}

const AGENT_PRESETS: Record<string, string> = {
  space: 'Space のログイン',
  openai: 'OpenAI API',
  anthropic: 'Anthropic API',
  openrouter: 'OpenRouter',
  deepseek: 'DeepSeek',
  ollama: 'Ollama Cloud',
  opencode: 'OpenCode Go',
  dsh: 'DeepSeek Harness',
  custom: 'カスタム',
};

function agentSection(botID: string): HTMLElement {
  const wrap = el('section', { class: 'panelBlock' });
  const head = el('div', { class: 'panelSectionRow' });
  head.append(sectionTitle('エージェント'));
  const edit = el('button', { class: 'ghost compact', type: 'button', id: 'agentEdit' });
  edit.append(icon('settings', 14), el('span', { text: '設定' }));
  edit.addEventListener('click', () => openAgent(botID));
  head.append(edit);
  wrap.append(head);

  let summary: string;
  if (!state.agentSet) {
    summary = '全体設定に従う（turn.env）';
  } else {
    const preset = state.agent.provider ? AGENT_PRESETS[state.agent.provider] : '';
    const harness = state.agent.harness || 'pi';
    const model = state.agent.model || 'Space の既定モデル';
    summary = [preset, harness, model].filter((part) => part !== '').join('・');
  }
  wrap.append(el('p', { class: 'panelNote', text: summary }));
  if (state.agentActive !== '') {
    const name = AGENT_PRESETS[state.agentActive] ?? state.agentActive;
    const until = state.agentUntil === '' ? '' : `${untilLabel(state.agentUntil)}まで`;
    wrap.append(
      el('p', {
        class: 'panelNote muted',
        text: until === '' ? `いま: ${name}` : `いま: ${name}（${until}）`,
      })
    );
  }
  return wrap;
}

export async function loadAgent(botID: string): Promise<void> {
  if (!botID) return;
  state.agentBot = botID;
  try {
    const payload = await api.agent(botID);
    if (state.agentBot !== botID) return;
    state.agent = payload.agent ?? {};
    state.agentSet = Boolean(payload.set);
    state.agentSchedule = payload.scheduleText ?? '';
    state.agentActive = payload.set ? (payload.activeName ?? '') : '';
    state.agentUntil = payload.set ? (payload.until ?? '') : '';
  } catch {
    // Keep the last summary; the button still opens the dialog.
  }
  if (state.panelOpen && state.panelTab === 'details' && state.current === botID) renderPanel();
}

function facts(botID: string): HTMLElement {
  const wrap = el('div', { class: 'facts' });
  const line = (label: string, value: string | Node): HTMLElement => {
    const row = el('div', { class: 'factRow' });
    row.append(
      el('span', { class: 'factLabel', text: label }),
      typeof value === 'string' ? el('span', { class: 'factValue', text: value }) : value
    );
    return row;
  };
  const space = state.botSpaces[botID] ?? '';
  const label = space ? spaceLabel(space) : '';
  wrap.append(
    line('状態', statePill(botID)),
    line('動かす場所', space ? (label === space ? space : `${label}（${space}）`) : '未設定')
  );
  return wrap;
}

function detailsTab(botID: string): HTMLElement {
  const wrap = el('div', { class: 'panelTabBody' });
  wrap.append(facts(botID));
  wrap.append(agentSection(botID));
  wrap.append(routinesSection());

  const actionsBlock = el('section', { class: 'panelBlock' });
  actionsBlock.append(sectionTitle('この Bot の管理'));
  const buttons = el('div', { class: 'buttonRow' });

  // The look is edited in a dialog: the swatch board took more room in the
  // panel than the routine and the Space facts it sat between.
  const look = el('button', { class: 'ghost', type: 'button' });
  look.append(icon('palette', 16), el('span', { text: '見た目を変える' }));
  look.addEventListener('click', () => openAvatar(botID));

  const pinned = isPinned(botID);
  const pin = el('button', {
    class: 'ghost',
    type: 'button',
    'aria-pressed': String(pinned),
    title: pinned ? '上部の大きなアイコンから外す' : '上部の大きなアイコンに並べる',
  });
  pin.append(icon('pin', 16), el('span', { text: pinned ? 'ピン留めを外す' : 'ピン留め' }));
  pin.addEventListener('click', async () => {
    pin.disabled = true;
    try {
      const res = isPinned(botID) ? await api.unpin(botID) : await api.pin(botID);
      if (!res.ok) {
        toast(`ピン留めを変えられませんでした (${res.status})`, 'error');
        return;
      }
      const payload = (await res.json()) as { bots?: string[] };
      applyPins(payload.bots ?? []);
      actions.refreshSidebar();
      renderPanel();
    } catch {
      toast('ピン留めを変えられませんでした', 'error');
    } finally {
      pin.disabled = false;
    }
  });

  const mint = el('button', { class: 'ghost', type: 'button' });
  mint.append(icon('key', 16), el('span', { text: '資格情報を発行' }));
  mint.addEventListener('click', () => openCredential(botID));

  const archived = state.archived.includes(botID);
  const archive = el('button', { class: 'ghost', type: 'button' });
  archive.append(icon('archive', 16), el('span', { text: archived ? '元に戻す' : 'アーカイブ' }));
  archive.addEventListener('click', async () => {
    if (!archived) {
      const ok = window.confirm(
        `${botID} をアーカイブします。Space と履歴は残り、資格情報は無効になります。`
      );
      if (!ok) return;
    }
    const res = await api.archive(botID, !archived);
    if (!res.ok) {
      toast(`できません: ${await res.text()}`, 'error');
      return;
    }
    await actions.refreshBots();
    renderPanel();
  });

  buttons.append(look, pin, mint, archive);
  actionsBlock.append(buttons);
  wrap.append(actionsBlock);
  return wrap;
}

function artifactRow(row: Artifact): HTMLElement {
  const item = el('div', { class: 'artifactRow' });
  const face = el('span', { class: 'artifactIcon' });
  face.append(icon('file', 18));
  const text = el(
    'span',
    { class: 'artifactText' },
    el('span', { class: 'artifactName', text: row.name, title: row.name }),
    el('span', {
      class: 'artifactMeta',
      text: `${row.ownerBotID}・${fmtBytes(row.byteCount)}・${fmtDateTime(row.createdAt)}`,
    }),
    el('span', {
      class: 'artifactSha',
      text: row.sha256 ? `sha256 ${row.sha256.slice(0, 12)}…` : '',
    })
  );
  const copy = el('button', {
    class: 'iconButton small',
    type: 'button',
    'aria-label': `${row.name} の sha256 をコピー`,
    title: 'sha256 をコピー',
  });
  copy.append(icon('copy', 15));
  copy.addEventListener('click', async () => {
    if (!row.sha256) return;
    const ok = await copyText(row.sha256);
    toast(ok ? 'sha256 をコピーしました' : 'コピーできませんでした', ok ? 'info' : 'error');
  });
  item.append(face, text, copy);
  return item;
}

function libraryTab(botID: string): HTMLElement {
  const wrap = el('div', { class: 'panelTabBody' });
  const head = el('div', { class: 'panelSectionRow' });
  head.append(sectionTitle('ライブラリ'));
  const refresh = el('button', { class: 'ghost compact', type: 'button' });
  refresh.append(icon('retry', 14), el('span', { text: '更新' }));
  refresh.addEventListener('click', () => void loadArtifacts(botID));
  head.append(refresh);
  wrap.append(head);

  if (state.artifactsError) {
    wrap.append(el('p', { class: 'panelNote', text: state.artifactsError }));
    const retry = el('button', { class: 'ghost', type: 'button', text: '再試行' });
    retry.addEventListener('click', () => void loadArtifacts(botID));
    wrap.append(retry);
    return wrap;
  }

  if (state.artifacts.length === 0) {
    const empty = el('div', { class: 'emptyCard' });
    empty.append(icon('library', 22));
    wrap.append(
      empty,
      el('p', { class: 'panelNote', text: 'まだ成果物がありません。' }),
      el('p', {
        class: 'panelNote muted',
        text: 'Bot がファイルを作り、成果物として登録すると、ここに記録されます。',
      })
    );
    return wrap;
  }

  const list = el('div', { class: 'artifactList' });
  for (const row of state.artifacts) list.append(artifactRow(row));
  wrap.append(list);
  wrap.append(
    el('p', {
      class: 'panelNote muted',
      text: '実体は Bot の Space の outputs / inbox にあります。この画面は記録の一覧です。',
    })
  );
  return wrap;
}

export async function loadArtifacts(botID: string): Promise<void> {
  if (!botID) return;
  state.artifactsBot = botID;
  state.artifactsError = '';
  try {
    const payload = await api.artifacts(botID);
    if (state.artifactsBot !== botID) return;
    state.artifacts = payload.artifacts ?? [];
  } catch {
    if (state.artifactsBot === botID) state.artifactsError = '成果物を読み込めませんでした。';
  }
  if (state.panelOpen && state.panelTab === 'library' && state.current === botID) renderPanel();
}

function computerTab(botID: string): HTMLElement {
  const wrap = el('div', { class: 'panelTabBody' });
  const space = currentSpaceState();
  const card = el('div', { class: 'computerCard' });
  card.append(
    el('span', { class: 'computerGlyph', text: '☾' }),
    el('span', {
      class: 'computerLabel',
      text:
        space?.state === 'pending'
          ? 'コンピューターを準備しています'
          : space?.state === 'failed'
            ? 'コンピューターを用意できませんでした'
            : 'コンピューターはスリープ中です',
    })
  );
  if (space?.detail) card.append(el('span', { class: 'computerDetail', text: space.detail }));
  wrap.append(card);
  wrap.append(
    el('p', {
      class: 'panelNote',
      text: '画面は SSH トンネル越しに開きます。ターミナルで cua-view を実行してください。',
    }),
    el('code', { class: 'codeLine', text: `cua-view ${state.botSpaces[botID] ?? ''}`.trim() })
  );
  return wrap;
}

export function renderPanel(): void {
  const panel = document.getElementById('panel');
  if (!panel) return;
  panel.hidden = !state.panelOpen;
  document.getElementById('app')?.classList.toggle('hasPanel', state.panelOpen);
  if (!state.panelOpen) return;

  const botID = state.current;
  const face = document.getElementById('panelFace');
  const name = document.getElementById('panelName');
  const body = document.getElementById('panelBody');
  if (!face || !name || !body) return;
  if (!botID) {
    face.replaceChildren();
    name.textContent = 'Bot を選んでください';
    clear(body);
    return;
  }
  const { mood } = presenceOf(botID);
  face.innerHTML = koalaHtml(state.avatars[botID], mood, 0, 'avatar panelFace');
  name.textContent = botID;

  document.querySelectorAll<HTMLButtonElement>('#panel .panelTab').forEach((tab) => {
    const active = tab.dataset.tab === state.panelTab;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
  });

  clear(body);
  if (state.panelTab === 'details') {
    if (state.agentBot !== botID) void loadAgent(botID);
    body.append(detailsTab(botID));
  } else if (state.panelTab === 'library') {
    if (state.artifactsBot !== botID) void loadArtifacts(botID);
    body.append(libraryTab(botID));
  } else body.append(computerTab(botID));

  if (panel.dataset.bot !== botID) {
    panel.dataset.bot = botID;
    void loadSpaceState(botID);
    void loadRoutines();
    void loadSpaces();
  }
}

export async function loadSpaceState(botID: string): Promise<void> {
  try {
    const space = await api.botSpace(botID);
    state.spaceStates[botID] = space;
    if (botID === state.current) {
      renderPanel();
      actions.refreshSidebar();
    }
  } catch {
    // A Bot without a provisioned Space has no state yet; leave it blank.
  }
}

export async function loadRoutines(): Promise<void> {
  const botID = state.current;
  if (!botID) return;
  try {
    const payload = await api.routines(botID);
    if (botID !== state.current) return;
    state.routines = payload.routines ?? [];
    if (state.panelOpen && state.panelTab === 'details') renderPanel();
  } catch {
    state.routines = [];
  }
}

async function loadSpaces(): Promise<void> {
  if (state.spaces.length > 0) return;
  try {
    const payload = await api.spaces();
    state.spaces = payload.spaces ?? [];
    state.spacesNote = payload.note ?? '';
    renderPanel();
  } catch {
    state.spacesNote = 'Space の一覧を取得できませんでした';
  }
}

export function openPanel(tab: PanelTab = 'details'): void {
  state.panelOpen = true;
  state.panelTab = tab;
  renderPanel();
  syncRoute();
}

export function closePanel(): void {
  state.panelOpen = false;
  renderPanel();
  syncRoute();
}

export function togglePanel(tab: PanelTab = 'details'): void {
  if (state.panelOpen && state.panelTab === tab) closePanel();
  else openPanel(tab);
}

export function initPanel(): void {
  const close = document.getElementById('panelClose');
  close?.addEventListener('click', () => closePanel());
  document.querySelectorAll<HTMLButtonElement>('#panel .panelTab').forEach((tab) => {
    tab.addEventListener('click', () => {
      state.panelTab = (tab.dataset.tab ?? 'details') as PanelTab;
      if (state.panelTab === 'library' && state.current) void loadArtifacts(state.current);
      renderPanel();
      syncRoute();
    });
  });
}