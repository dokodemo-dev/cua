// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import { useEffect } from "react";
import { create } from "zustand";
import { useSettings } from "@/bridge";
import {
  LANGUAGE_STORAGE_KEY,
  normalizePreference,
  resolveLanguage,
  translate,
  type LanguagePreference,
} from "./i18n-core";

function readPreference(): LanguagePreference {
  try {
    return normalizePreference(globalThis.localStorage?.getItem(LANGUAGE_STORAGE_KEY));
  } catch {
    return "system";
  }
}
export const useLanguageStore = create<{
  preference: LanguagePreference;
  systemLanguages: readonly string[];
  setPreference(value: LanguagePreference): void;
}>((set) => ({
  preference: readPreference(),
  systemLanguages: typeof navigator === "undefined" ? [] : [...navigator.languages],
  setPreference: (preference) => {
    // Native hosts persist before calling this; browser-only hosts use localStorage.
    globalThis.localStorage?.setItem(LANGUAGE_STORAGE_KEY, preference);
    set({ preference });
  },
}));
export function useI18n() {
  const preference = useLanguageStore((s) => s.preference);
  const systemLanguages = useLanguageStore((s) => s.systemLanguages);
  const language = resolveLanguage(preference, systemLanguages);
  return {
    preference,
    language,
    t: (key: string, args?: Record<string, string>) => translate(language, key, args),
  };
}
export function useLanguageSync(): void {
  const { language } = useI18n();
  const { data } = useSettings();
  const hostPreference = data?.values.language;
  useEffect(() => {
    if (hostPreference !== undefined) {
      const preference = normalizePreference(hostPreference);
      // Storage is only a cache on a native host; never overwrite its saved preference on mount.
      useLanguageStore.setState({ preference });
    }
  }, [hostPreference]);
  useEffect(() => {
    document.documentElement.lang = language;
  }, [language]);
  useEffect(() => {
    const update = () => useLanguageStore.setState({ preference: readPreference() });
    const changed = () => useLanguageStore.setState({ systemLanguages: [...navigator.languages] });
    const storage = (event: StorageEvent) => {
      if (hostPreference === undefined && event.key === LANGUAGE_STORAGE_KEY) update();
    };
    window.addEventListener("storage", storage);
    window.addEventListener("languagechange", changed);
    return () => {
      window.removeEventListener("storage", storage);
      window.removeEventListener("languagechange", changed);
    };
  }, [hostPreference]);
}