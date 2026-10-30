// The address bar says what is on screen: `/ui/<bot>`, `/ui/<bot>/<tab>` and
// `/ui/settings/<section>`. That makes the back and forward buttons work, a
// reload land where it was, and a link point at one Bot's library instead of
// at whatever the page happened to show.
//
// `settings` is also a legal Bot id, so the first segment is resolved against
// the Bot list first: a Bot named `settings` wins, and the settings dialog is
// reachable from the gear button in that (unlikely) case.

import { actions } from './deps';
import { state, type PanelTab } from './store';

export type SettingsSection = 'general' | 'access' | 'spaces' | 'keys' | 'chat' | 'screen';

const TABS: PanelTab[] = ['details', 'library', 'computer'];
const SECTIONS: SettingsSection[] = ['general', 'access', 'spaces', 'keys', 'chat', 'screen'];

function isTab(value: string): value is PanelTab {
  return (TABS as string[]).includes(value);
}

function isSection(value: string): value is SettingsSection {
  return (SECTIONS as string[]).includes(value);
}

// True while the page is being put into the state the address bar describes.
// Every writer checks it, so applying a route never writes another entry.
let applying = false;

export function isApplyingRoute(): boolean {
  return applying;
}

/** The settings dialog that is open, and its section, or null. */
function openSettingsSection(): SettingsSection | null {
  const dialog = document.getElementById('settingsDialog') as HTMLDialogElement | null;
  if (!dialog?.open) return null;
  const selected = document.querySelector<HTMLButtonElement>('#settingsNav [aria-selected="true"]');
  const name = selected?.dataset.section ?? 'general';
  return isSection(name) ? name : 'general';
}

/** The path that matches what is on screen now. */
export function pathForState(): string {
  const section = openSettingsSection();
  if (section) return `/ui/settings/${section}`;
  if (!state.current) return '/ui';
  return state.panelOpen ? `/ui/${state.current}/${state.panelTab}` : `/ui/${state.current}`;
}

/** What the entry we wrote describes, so closing a dialog can step back. */
interface EntryState {
  view?: 'bot' | 'settings';
}

function tagFor(path: string): EntryState {
  return { view: path.startsWith('/ui/settings') ? 'settings' : 'bot' };
}

/**
 * Writes the current view into history. `replace` is for a change inside the
 * same view (another settings section, the first render).
 */
export function syncRoute(replace = false): void {
  if (applying) return;
  const path = pathForState();
  if (location.pathname === path) return;
  const url = `${path}${location.search === '?login=failed' ? location.search : ''}`;
  if (replace) history.replaceState(tagFor(path), '', url);
  else history.pushState(tagFor(path), '', url);
}

/**
 * What to do when a dialog closes on its own (the close button, Escape):
 * step back to the view the dialog was opened from, rather than leaving an
 * entry that points at a dialog nobody can see.
 */
export function routeAfterClose(): void {
  if (applying) return;
  const tag = history.state as EntryState | null;
  if (tag?.view === 'settings') {
    history.back();
    return;
  }
  syncRoute();
}

/** Reads the address bar and puts the page in that state. */
export function applyRoute(): void {
  const parts = location.pathname
    .replace(/^\/ui\/?/, '')
    .split('/')
    .filter((part) => part !== '');
  const first = parts[0] ? decodeURIComponent(parts[0]) : '';
  const second = parts[1] ? decodeURIComponent(parts[1]) : '';

  applying = true;
  try {
    if (first === 'settings' && !state.bots.includes('settings')) {
      actions.openSettings(isSection(second) ? second : 'general');
      return;
    }
    // Any other view means the settings dialog, if open, is not what the
    // address bar describes.
    actions.closeSettings();
    if (!first) return;
    if (!state.bots.includes(first)) return;
    if (state.current !== first) actions.selectBot(first);
    if (isTab(second)) actions.openPanel(second);
    else actions.closePanel();
  } finally {
    // Dialog events fire synchronously on close; release on the next tick so
    // they do not write another entry.
    window.setTimeout(() => {
      applying = false;
    }, 0);
  }
}