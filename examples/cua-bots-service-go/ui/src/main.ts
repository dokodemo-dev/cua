// Boot: read the credential, load the Bot list, then let each part of the page
// take over. Everything here is wiring; behaviour lives in the modules.

import { ApiError, api, clearCredential, takeFragmentCredential } from './api';
import { initChat, paintStatusPill, pollNow, refreshComposer, resetThread } from './chat';
import { setActions } from './deps';
import { icon, toast } from './dom';
import { closeSettings, initModals, openNewBot, openSearch, openSettings } from './modals';
import { applyRoute, syncRoute } from './route';
import {
  closePanel,
  initPanel,
  loadRoutines,
  loadSpaceState,
  openPanel,
  renderPanel,
  togglePanel,
} from './panel';
import { initSidebar, renderAccount, renderSidebar } from './sidebar';
import { PREF, applyPins, preference, setPreference, state } from './store';
import { applyTheme } from './theme';

function fillIcons(): void {
  const slots: [string, Parameters<typeof icon>[0], number][] = [
    ['openSearch', 'search', 20],
    ['openNewBot', 'plus', 20],
    ['openSidebar', 'menu', 20],
    ['panelClose', 'close', 18],
    ['send', 'send', 18],
    ['composerPlus', 'plus', 18],
  ];
  for (const [id, name, size] of slots) {
    const slot = document.getElementById(id);
    if (slot) slot.replaceChildren(icon(name, size));
  }
  document.querySelectorAll<HTMLElement>('.searchIcon').forEach((slot) => {
    slot.replaceChildren(icon('search', 18));
  });
  document.querySelectorAll<HTMLElement>('.sheetClose').forEach((slot) => {
    slot.replaceChildren(icon('close', 18));
  });
}

function showGate(visible: boolean): void {
  const gate = document.getElementById('gate');
  if (gate) gate.hidden = !visible;
  document.getElementById('app')?.classList.toggle('signedOut', visible);
  refreshComposer();
}

function signedOut(): void {
  state.signedIn = false;
  state.session = null;
  state.turns = [];
  state.cursor = 0;
  resetThread();
  renderSidebar();
  renderAccount();
  showGate(true);
  renderPanel();
}

function selectBot(botID: string): void {
  if (!botID) return;
  state.current = botID;
  state.artifacts = [];
  state.artifactsBot = '';
  state.artifactsError = '';
  state.agent = {};
  state.agentSet = false;
  state.agentBot = '';
  setPreference(PREF.bot, botID);
  resetThread();
  renderSidebar();
  renderAccount();
  renderPanel();
  paintStatusPill();
  refreshComposer();
  showGate(false);
  void loadSpaceState(botID);
  void loadRoutines();
  void pollNow();
  document.getElementById('thread')?.scrollIntoView({ block: 'start' });
  if (window.innerWidth <= 900) document.body.classList.remove('sidebarOpen');
  syncRoute();
}

async function refreshBots(): Promise<void> {
  try {
    const payload = await api.bots(true);
    state.signedIn = true;
    state.bots = payload.bots ?? [];
    state.archived = payload.archived ?? [];
    state.avatars = { ...state.avatars, ...payload.avatars };
    state.botSpaces = payload.spaces ?? {};
    state.botActivity = payload.activity ?? {};
    try {
      applyPins((await api.pins()).bots ?? []);
    } catch {
      // A Bot credential cannot read the operator's pins; keep the last row.
      applyPins(state.pinned);
    }
    const wanted = preference(PREF.bot) ?? '';
    if (!state.bots.includes(state.current)) {
      state.current = state.bots.includes(wanted) ? wanted : (state.bots[0] ?? '');
      resetThread();
    }
    renderSidebar();
    renderAccount();
    renderPanel();
    paintStatusPill();
    refreshComposer();
    showGate(false);
    try {
      state.session = await api.session();
    } catch {
      state.session = null;
    }
    renderAccount();
    if (state.current) void loadRoutines();
  } catch (error) {
    if (error instanceof ApiError && error.status === 401) {
      signedOut();
      return;
    }
    if (error instanceof ApiError && error.status === 429) {
      toast('混み合っています。少し待ってから更新します。', 'error');
      return;
    }
    toast('Bot の一覧を読み込めませんでした。接続を確認してください。', 'error');
  }
}

function bootstrap(): void {
  takeFragmentCredential();
  // A sign-out is a sign-out even when the page is opened with the query alone.
  if (location.search.includes('logout=1')) {
    clearCredential();
    history.replaceState(null, '', '/ui');
  }

  applyTheme();
  fillIcons();

  setActions({
    selectBot,
    openPanel,
    closePanel,
    closeSettings,
    togglePanel,
    openSettings: (section) => openSettings(section ?? 'general'),
    openNewBot: () => void openNewBot(),
    openSearch,
    signedOut,
    refreshBots,
    refreshSidebar: renderSidebar,
    refreshPanel: renderPanel,
    loadRoutines,
  });

  initSidebar();
  initPanel();
  initChat();
  initModals();

  showGate(false);
  refreshComposer();

  document.getElementById('main')?.addEventListener('click', (event) => {
    if ((event.target as HTMLElement).closest('.composer, .statusPill')) return;
    document.body.classList.remove('sidebarOpen');
  });

  void refreshBots().then(() => {
    if (!state.signedIn) {
      showGate(true);
      return;
    }
    // The Bot list decides whether `/ui/<name>` is a Bot or a section, so the
    // address bar is read after it arrives. applyRoute releases its guard on
    // the next tick, which is when the first entry can be written.
    applyRoute();
    window.setTimeout(() => syncRoute(true), 0);
    if (state.current) void pollNow();
  });
}

bootstrap();