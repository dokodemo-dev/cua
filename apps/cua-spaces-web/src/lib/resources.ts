// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

/**
 * The words and bar fills for processor, memory and disk numbers
 * (CUA-1880). Plain labels only: "Processor", "Memory", "Space for files",
 * "busy", "in use", "free". Never vCPU, RSS, APFS, sparse or cgroup.
 */

import type { ComputerResources, SpaceResources } from "@/bridge";
import { identityTranslate, type Translate } from "@/lib/i18n-core";

export const LABELS = { cpu: "Processor", memory: "Memory", disk: "Space for files" } as const;

/** The three card labels in the chosen language. */
export function labels(t: Translate = identityTranslate) {
  return { cpu: t(LABELS.cpu), memory: t(LABELS.memory), disk: t(LABELS.disk) };
}

const GB = 1_000_000_000;

/** A number of GB as people read it: "3.1", "41", "8". */
function gbNumber(bytes: number): string {
  const tenths = Math.round((bytes / GB) * 10) / 10;
  return tenths >= 9.95 || Number.isInteger(tenths) ? String(Math.round(tenths)) : tenths.toFixed(1);
}

/** "41 GB", "3.1 GB", "1 TB", "1.5 TB". */
export function size(bytes: number): string {
  if (bytes >= 999.5 * GB) {
    const tb = Math.round(bytes / (GB * 100)) / 10;
    return `${Number.isInteger(tb) ? tb.toFixed(0) : tb.toFixed(1)} TB`;
  }
  return `${gbNumber(bytes)} GB`;
}

/** "3.1 of 8 GB" (same unit) or "800 GB of 1 TB". */
export function sizeOf(used: number, total: number): string {
  const whole = size(total);
  const unit = whole.split(" ")[1];
  const part = size(used);
  return part.endsWith(` ${unit}`) ? `${part.split(" ")[0]} of ${whole}` : `${part} of ${whole}`;
}

export const cores = (n: number, t: Translate = identityTranslate) =>
  n === 1 ? t("1 core") : t("{count} cores", { count: String(n) });

/** A bar's fill, 0 to 1. */
export const fill = (part: number | null | undefined, whole: number | null | undefined) =>
  part == null || !whole ? 0 : Math.min(1, Math.max(0, part / whole));

/** How long ago another computer measured: "just now", "2 min ago", "3 hours ago". */
export function updatedAgo(
  sampledAtMs: number, now: number, t: Translate = identityTranslate,
): string {
  const min = Math.floor((now - sampledAtMs) / 60_000);
  if (min < 1) return t("just now");
  if (min < 60) return t("{count} min ago", { count: String(min) });
  const h = Math.floor(min / 60);
  if (h < 24) {
    return h === 1 ? t("1 hour ago") : t("{count} hours ago", { count: String(h) });
  }
  const d = Math.floor(h / 24);
  return d === 1 ? t("1 day ago") : t("{count} days ago", { count: String(d) });
}

export interface Meter {
  label: string;
  value: string;
  /** 0 to 1. */
  fill: number;
  tone?: "warning" | "critical";
  /** The longer words, for a tooltip. */
  help?: string;
}

const tone = (c: ComputerResources): Meter["tone"] => (c.warning.level === "critical" ? "critical" : c.warning.level === "low" ? "warning" : undefined);

/** A computer's three meters: "12 cores · 38% busy", "41 of 64 GB in use", "41 GB free of 1 TB". */
export function hostMeters(c: ComputerResources, t: Translate = identityTranslate): Meter[] {
  return [
    {
      label: t(LABELS.cpu),
      value: `${cores(c.cpuCount, t)} · ${t("{percent}% busy", { percent: String(Math.round(c.cpuPercent)) })}`,
      fill: fill(c.cpuPercent, 100),
    },
    {
      label: t(LABELS.memory),
      value: t("{amount} in use", { amount: sizeOf(c.memoryUsed, c.memoryTotal) }),
      fill: fill(c.memoryUsed, c.memoryTotal),
    },
    {
      label: t(LABELS.disk),
      value: t("{free} free of {total}", { free: size(c.diskFree), total: size(c.diskTotal) }),
      fill: fill(c.diskTotal - c.diskFree, c.diskTotal),
      tone: tone(c),
    },
  ];
}

/** "Your extra Spaces use 6 cores, 12 GB of memory and about 25 GB for files." Null with none. */
export function extraSpacesLine(
  c: ComputerResources, where: "here" | "there", t: Translate = identityTranslate,
): string | null {
  if (!c.spacesCount) return null;
  const template =
    where === "there"
      ? "Your extra Spaces there use {cpu}, {memory} of memory and about {disk} for files."
      : "Your extra Spaces use {cpu}, {memory} of memory and about {disk} for files.";
  return t(template, {
    cpu: cores(c.spacesCpuAllocated, t),
    memory: size(c.spacesMemoryAllocated),
    disk: size(c.spacesDiskBytes),
  });
}

export const isRunning = (s: SpaceResources) => s.powerState === "running";

/**
 * What a Space costs this Mac's disk, by the contract's rule: "Uses about
 * 19 GB on this Mac", plus "(shares space with other copies)" when it does;
 * "Shares space with other copies" when it couldn't be measured; null when
 * there's nothing to say.
 */
export function onHostLine(
  s: SpaceResources, computer = "this Mac", t: Translate = identityTranslate,
): string | null {
  const d = s.diskOnHost;
  if (!d) return null;
  if (d.bytes == null) {
    return d.sharesSpace ? t("Shares space with other copies.") : null;
  }
  const template = d.sharesSpace
    ? "Uses about {size} on {computer} (shares space with other copies)."
    : "Uses about {size} on {computer}.";
  return t(template, { size: size(d.bytes), computer });
}

/** A Space's three short meters on its tile: "22% busy", "3.1 of 8 GB", "About 19 GB" (the
 * tooltip and the Space's page say the rest). */
export function spaceMeters(s: SpaceResources, t: Translate = identityTranslate): Meter[] {
  const on = isRunning(s) && s.usage !== null;
  const u = s.usage;
  const memTotal = s.memoryAllocated || u?.memoryTotal || 0;
  const onHost = s.diskOnHost?.bytes ?? null;
  const busy = (percent: number) => t("{percent}% busy", { percent: String(Math.round(percent)) });
  return [
    {
      label: t(LABELS.cpu),
      value: on ? busy(u!.cpuPercent) : t("Stopped"),
      fill: on ? fill(u!.cpuPercent, 100) : 0,
      help: s.cpuAllocated
        ? on
          ? `${cores(s.cpuAllocated, t)} · ${busy(u!.cpuPercent)}`
          : t("Given {amount}", { amount: cores(s.cpuAllocated, t) })
        : undefined,
    },
    {
      label: t(LABELS.memory),
      value:
        on && memTotal ? sizeOf(u!.memoryUsed, memTotal) : on ? size(u!.memoryUsed) : t("Off"),
      fill: on ? fill(u!.memoryUsed, memTotal) : 0,
      help: s.memoryAllocated
        ? t("Given {amount}", { amount: size(s.memoryAllocated) })
        : undefined,
    },
    {
      label: t(LABELS.disk),
      value:
        onHost != null
          ? t("About {amount}", { amount: size(onHost) })
          : s.diskAllocated
            ? t("Up to {amount}", { amount: size(s.diskAllocated) })
            : "—",
      fill: fill(onHost, s.diskAllocated),
      help: onHostLine(s, "this Mac", t) ?? undefined,
    },
  ];
}

/** The low-disk warning's words, or null when there's room. */
export function lowDiskWarning(
  c: ComputerResources, computer: string, t: Translate = identityTranslate,
): { level: "low" | "critical"; title: string; detail: string } | null {
  const level = c.warning.level;
  if (level === "ok") return null;
  const free = t("{free} free of {total}.", {
    free: size(c.diskFree), total: size(c.diskTotal),
  });
  return level === "critical"
    ? {
        level,
        title: t("{computer} is out of space. Delete old Spaces or snapshots.", { computer }),
        detail: t("{free} New Spaces can’t start until there’s more room.", { free }),
      }
    : {
        level,
        title: t("{computer} is almost out of space. Delete old Spaces or snapshots.", {
          computer,
        }),
        detail: t("{free} New Spaces may not fit, and apps can slow down.", { free }),
      };
}

/** The pieces of "How it fits on this Mac": your own files, each Space, and free. */
export function diskParts(c: ComputerResources, spaces: { name: string; bytes: number }[]): { own: number; free: number } {
  const used = c.diskTotal - c.diskFree;
  const inSpaces = spaces.reduce((n, s) => n + s.bytes, 0);
  return { own: Math.max(0, used - inSpaces), free: c.diskFree };
}
