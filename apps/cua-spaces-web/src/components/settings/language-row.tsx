// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import { useState } from "react";
import { useSettings } from "@/bridge";
import { SettingsRow } from "@/components/settings-group";
import { useI18n, useLanguageStore } from "@/lib/i18n";
import { normalizePreference } from "@/lib/i18n-core";

export function LanguageRow() {
  const { data, updateSetting } = useSettings();
  const { preference, t } = useI18n();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const choose = async (value: string) => {
    setPending(true);
    setError(null);
    try {
      const next = normalizePreference(value);
      if (data?.values.language !== undefined) {
        await updateSetting("language", next);
        useLanguageStore.setState({ preference: next });
      } else {
        useLanguageStore.getState().setPreference(next);
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setPending(false);
    }
  };
  return (
    <>
      <SettingsRow
        label={t("Language")}
        htmlFor="display-language"
        description={t("Language settings apply to the interface, not agent replies.")}
        control={
          <select
            id="display-language"
            aria-label={t("Language")}
            value={preference}
            disabled={pending || !data}
            className="h-7 min-w-36 rounded-md border border-input bg-card px-2 text-[13px] outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
            onChange={(event) => void choose(event.currentTarget.value)}
          >
            <option value="system">{t("System")}</option>
            <option value="ja">日本語</option>
            <option value="en">English</option>
          </select>
        }
      />
      {error ? (
        <p role="alert" className="px-4 py-2 text-xs text-destructive">
          {error}
        </p>
      ) : null}
    </>
  );
}