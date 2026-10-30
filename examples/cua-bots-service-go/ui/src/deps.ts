import type { SettingsSection } from './route';
import type { PanelTab } from './store';

export interface Actions {
  selectBot(botID: string): void;
  openPanel(tab?: PanelTab): void;
  closePanel(): void;
  closeSettings(): void;
  togglePanel(tab?: PanelTab): void;
  openSettings(section?: SettingsSection): void;
  openNewBot(): void;
  openSearch(): void;
  signedOut(): void;
  refreshBots(): Promise<void>;
  refreshSidebar(): void;
  refreshPanel(): void;
  loadRoutines(): Promise<void>;
}

// Wired once by main.ts. Modules call through this object instead of importing
// each other, so the module graph stays a tree.
export const actions = {} as Actions;

export function setActions(next: Actions): void {
  Object.assign(actions, next);
}