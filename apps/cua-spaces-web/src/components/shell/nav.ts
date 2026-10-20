// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { BellIcon, BotIcon, HardDriveIcon, KeyRoundIcon, LayoutGridIcon, ServerIcon, SettingsIcon, type LucideIcon } from "lucide-react";

import { useExperimentFlags } from "@/bridge";
import type { KeybindingCommand } from "@/lib/keybindings";
import { useI18n } from "@/lib/i18n";

export interface NavItem {
  to: "/spaces" | "/machines" | "/agents" | "/volume" | "/keyvault" | "/notifications" | "/settings";
  label: string;
  icon: LucideIcon;
  /** Its keyboard shortcut, when it has one. */
  command?: KeybindingCommand;
}

export const NAV_ITEMS: NavItem[] = [
  { to: "/spaces", label: "Spaces", icon: LayoutGridIcon, command: "nav.spaces" },
  { to: "/machines", label: "Computers", icon: ServerIcon, command: "nav.machines" },
  { to: "/agents", label: "Agents", icon: BotIcon, command: "nav.agents" },
  { to: "/keyvault", label: "Keyvault", icon: KeyRoundIcon, command: "nav.keyvault" },
  { to: "/notifications", label: "Notifications", icon: BellIcon },
  { to: "/settings", label: "Settings", icon: SettingsIcon, command: "nav.settings" },
];

/** The sidebar's Volume entry (the core's `volumeLabel`), after Agents. */
const VOLUME_ITEM: NavItem = { to: "/volume", label: "Volume", icon: HardDriveIcon };

/** The nav, with Volume while the Cua Volume experiment is on. */
export function useNavItems(): NavItem[] {
  const experiments = useExperimentFlags();
  const { t } = useI18n();
  const translated = NAV_ITEMS.map((item) => ({ ...item, label: t(item.label) }));
  if (!experiments?.cuaVolume) return translated;
  const i = NAV_ITEMS.findIndex((n) => n.to === "/agents") + 1;
  return [...translated.slice(0, i), { ...VOLUME_ITEM, label: t(VOLUME_ITEM.label) }, ...translated.slice(i)];
}
