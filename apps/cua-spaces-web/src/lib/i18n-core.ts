// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import en from "../../../../libs/cua-localization/Sources/CuaLocalization/Resources/en.json";
import ja from "../../../../libs/cua-localization/Sources/CuaLocalization/Resources/ja.json";

export type LanguagePreference = "system" | "ja" | "en";
export type DisplayLanguage = "ja" | "en";
export const LANGUAGE_STORAGE_KEY = "cua.settings.language";
export const catalogs: Record<DisplayLanguage, Record<string, string>> = { en, ja };
export function normalizePreference(value: unknown): LanguagePreference {
  return value === "ja" || value === "en" ? value : "system";
}
export function resolveLanguage(
  preference: LanguagePreference,
  preferred: readonly string[],
): DisplayLanguage {
  if (preference !== "system") return preference;
  const first = (preferred[0] ?? "en").toLowerCase().replaceAll("_", "-");
  return first === "ja" || first.startsWith("ja-") ? "ja" : "en";
}
export function translate(
  language: DisplayLanguage,
  key: string,
  args: Record<string, string> = {},
): string {
  const template = Object.hasOwn(catalogs[language], key)
    ? catalogs[language][key]
    : Object.hasOwn(catalogs.en, key)
      ? catalogs.en[key]
      : key;
  return (template ?? key).replace(/\{([A-Za-z][A-Za-z0-9_]*)\}/g, (placeholder, name: string) =>
    Object.hasOwn(args, name) ? (args[name] ?? placeholder) : placeholder,
  );
}