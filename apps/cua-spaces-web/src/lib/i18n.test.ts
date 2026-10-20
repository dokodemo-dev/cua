// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import { describe, expect, it } from "vitest";
import { resolveLanguage, translate, normalizePreference, catalogs } from "./i18n-core";

describe("shared display language", () => {
  it("respects explicit preference and only the primary OS language", () => {
    expect(resolveLanguage("system", ["ja-JP", "en"])).toBe("ja");
    expect(resolveLanguage("system", ["fr-FR", "ja"])).toBe("en");
    expect(resolveLanguage("en", ["ja"])).toBe("en");
    expect(normalizePreference("invalid")).toBe("system");
  });
  it("uses the same catalog keys, preserves placeholders and falls back to English", () => {
    expect(Object.keys(catalogs.ja).sort()).toEqual(Object.keys(catalogs.en).sort());
    for (const key of Object.keys(catalogs.en)) {
      expect(catalogs.ja[key]?.match(/\{\w+\}/g)?.sort() ?? []).toEqual(
        catalogs.en[key]?.match(/\{\w+\}/g)?.sort() ?? [],
      );
    }
    expect(translate("ja", "New bot")).toBe("新しいBot");
    expect(translate("ja", "Untranslated text")).toBe("Untranslated text");
    expect(translate("ja", "constructor")).toBe("constructor");
    expect(translate("ja", "{toString}")).toBe("{toString}");
    expect(translate("ja", "Create {name}", { name: "demo" })).toBe("demoを作成");
    expect(translate("ja", "Create {name}", { name: "$&" })).toBe("$&を作成");
    expect(translate("ja", "Show in menu bar")).toBe("メニューバーに表示");
    expect(translate("ja", "Open Cua Spaces from the menu bar instead of the notch.")).toBe("ノッチの代わりにメニューバーからCua Spacesを開きます。");
    expect(translate("ja", "Set by {source}.", { source: "CUA_SPACES_DEFAULT_LOCATION" })).toBe("CUA_SPACES_DEFAULT_LOCATIONで設定されています。");
  });
});