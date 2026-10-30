// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import type { Machine, SpaceOs } from "@/bridge";
import { OS_NAME } from "@/components/os-icon";
import { identityTranslate, type Translate } from "@/lib/i18n-core";
import { relativeTime } from "@/lib/utils";

/** The machine's OS as one of the three the app draws, or null when the host did not say. */
export function machineOs(m: Pick<Machine, "os">): SpaceOs | null {
  const os = m.os.toLowerCase();
  if (os === "macos" || os === "darwin" || os === "mac") return "macos";
  if (os === "windows" || os === "win32") return "windows";
  if (os === "linux") return "linux";
  return null;
}

/** "macOS", or "Unknown OS". */
export function osName(m: Pick<Machine, "os">, t: Translate = identityTranslate): string {
  const os = machineOs(m);
  return os ? OS_NAME[os] : t("Unknown OS");
}

export const CONNECTION_LABEL: Record<"relay" | "direct", string> = {
  relay: "Cua relay",
  direct: "Direct",
};

/** How other devices reach it, in words. */
export function connectionLabel(
  m: Pick<Machine, "connection" | "current"> & Pick<Partial<Machine>, "device">,
  t: Translate = identityTranslate,
): string {
  if (m.connection) return t(CONNECTION_LABEL[m.connection]);
  return m.current || m.device ? t("Not set up for access") : t("Unknown");
}

/** The list row's second line: OS, then how it is reached. */
export function machineSubtitle(
  m: Pick<Machine, "os" | "connection" | "current" | "model"> & Pick<Partial<Machine>, "device">,
  t: Translate = identityTranslate,
): string {
  return [m.model ?? osName(m, t), connectionLabel(m, t)].join(" · ");
}

/** The core's word for a machine its owner stopped sharing
 * (`machines::NOT_SHARING`): connected to the relay, but it refuses every
 * call. */
export const NOT_SHARING = "Not sharing";

/** Usable from here: online and shared (a machine whose owner stopped
 * sharing it is connected, but nothing here can reach it). */
export const reachable = (m: Pick<Machine, "online" | "notSharing">): boolean => m.online && !m.notSharing;

/** The detail's line: the row's word, and when an offline machine was
 * last seen. */
export function presenceLabel(
  m: Pick<Machine, "online" | "lastSeen" | "notSharing" | "status">,
  now: number,
  t: Translate = identityTranslate,
): string {
  if (m.online || !m.lastSeen) return presenceWord(m, t);
  return t("Offline, last seen {when}", { when: relativeTime(m.lastSeen * 1000, now) });
}

/** The list row's one word: the core's (`machines::status_word`, the same
 * the SwiftUI Machines list shows): "Online", "Not sharing" or "Offline". */
export function presenceWord(
  m: Pick<Machine, "online" | "notSharing" | "status">,
  t: Translate = identityTranslate,
): string {
  if (m.status) return t(m.status);
  if (!m.online) return t("Offline");
  return m.notSharing ? t(NOT_SHARING) : t("Online");
}

/** "1 Space", "3 Spaces", "No Spaces". */
export function spaceCount(n: number, t: Translate = identityTranslate): string {
  if (n === 0) return t("No Spaces");
  return n === 1 ? t("1 Space") : t("{count} Spaces", { count: String(n) });
}

/** The row's Spaces count: the core's (`machines::spaces_label`, the same
 * the SwiftUI Machines list shows), else `n` counted here. Empty for a
 * device of its own (it runs no Spaces). */
export function spacesLabel(
  m: Pick<Machine, "spacesLabel">, n: number, t: Translate = identityTranslate,
): string {
  return m.spacesLabel != null ? t(m.spacesLabel) : spaceCount(n, t);
}

/** The selected machine: the chosen one if it is still listed, else the first. */
export function selectedMachine<T extends Pick<Machine, "id">>(machines: readonly T[], id: string | null): T | undefined {
  return machines.find((m) => m.id === id) ?? machines[0];
}

/** The Machines header: "1 computer, 1 online", "3 computers, 2 online". */
export function machinesSummary(
  total: number, online: number, t: Translate = identityTranslate,
): string {
  const counts = { total: String(total), online: String(online) };
  return total === 1
    ? t("1 computer, {online} online", counts)
    : t("{total} computers, {online} online", counts);
}
