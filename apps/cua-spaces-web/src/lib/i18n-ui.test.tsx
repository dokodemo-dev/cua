// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { LanguageRow } from "@/components/settings/language-row";
import { useI18n, useLanguageStore, useLanguageSync } from "./i18n";

const host = vi.hoisted(() => ({
  data: { values: {} as { language?: "system" | "ja" | "en" } },
  updateSetting: vi.fn(),
}));
vi.mock("@/bridge", () => ({ useSettings: () => host }));
function Preview() {
  useLanguageSync();
  const { t } = useI18n();
  return (
    <>
      <h1>{t("Settings")}</h1>
      <LanguageRow />
    </>
  );
}
beforeEach(() => {
  localStorage.clear();
  host.data = { values: {} };
  host.updateSetting.mockReset().mockResolvedValue(undefined);
  useLanguageStore.setState({ preference: "en", systemLanguages: ["en-US"] });
});
afterEach(cleanup);
it("changes language and document lang, preserving the choice across a browser remount", async () => {
  const view = render(<Preview />);
  fireEvent.change(screen.getByRole("combobox", { name: "Language" }), { target: { value: "ja" } });

  await screen.findByRole("heading", { name: "設定" });
  expect(document.documentElement.lang).toBe("ja");
  expect(localStorage.getItem("cua.settings.language")).toBe("ja");
  expect(host.updateSetting).not.toHaveBeenCalled();
  view.unmount();
  render(<Preview />);
  expect(screen.getByRole("heading", { name: "設定" })).toBeTruthy();
});
it("loads the native preference without writing it back or overwriting it with a stale browser value", async () => {
  localStorage.setItem("cua.settings.language", "en");
  host.data = { values: { language: "ja" } };
  render(<Preview />);
  await screen.findByRole("heading", { name: "設定" });
  expect(host.updateSetting).not.toHaveBeenCalled();
});
it("keeps the current language and exposes failed native saves", async () => {
  host.data = { values: { language: "en" } };
  host.updateSetting.mockRejectedValue(new Error("save failed"));
  render(<Preview />);
  fireEvent.change(screen.getByRole("combobox", { name: "Language" }), { target: { value: "ja" } });

  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("save failed"));
  expect(host.updateSetting).toHaveBeenCalledWith("language", "ja");
  expect(screen.getByRole("heading", { name: "Settings" })).toBeTruthy();
});