// Theme preference: follow the system unless the operator pins one.
// `light-dark()` in app.css does the actual colour picking; this module only
// controls `color-scheme`, so there is nothing to re-render on a change.

import { PREF, preference, setPreference, type ThemePref } from './store';

const MEDIA = '(prefers-color-scheme: light)';

export function themePreference(): ThemePref {
  const value = preference(PREF.theme);
  return value === 'light' || value === 'dark' ? value : 'system';
}

export function applyTheme(pref: ThemePref = themePreference()): void {
  const root = document.documentElement;
  if (pref === 'system') delete root.dataset.theme;
  else root.dataset.theme = pref;
}

export function setTheme(pref: ThemePref): void {
  if (pref === 'system') setPreference(PREF.theme, 'system');
  else setPreference(PREF.theme, pref);
  applyTheme(pref);
}

export function systemTheme(): 'light' | 'dark' {
  return window.matchMedia?.(MEDIA).matches ? 'light' : 'dark';
}

export function effectiveTheme(): 'light' | 'dark' {
  const pref = themePreference();
  return pref === 'system' ? systemTheme() : pref;
}