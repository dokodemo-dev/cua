// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import { describe, expect, it } from "vitest";

import { core } from "../core";
import { settingsPage } from "./window";

/**
 * Settings > Privacy has to show the switch the app is actually using.
 * A locked row (DO_NOT_TRACK, or a config file) must read Off and be disabled,
 * not merely carry a note while the "On" pill stays selected.
 */
describe("the Privacy switch follows the shell's telemetry decision", () => {
  const page = (telemetry: { enabled: boolean; lockedBy: string | null } | null) => {
    // The core is initialised by the test environment; a call through it is
    // what the panel makes.
    void core;
    return settingsPage({
      telemetry,
      menuBar: false,
      defaultLocation: "local",
      canSignOut: false,
      signIn: { kind: "idle" },
      agents: [],
      agentsBusy: false,
      agentsPending: [],
      experiments: { cuaVolume: false, yourCloud: false, sharing: false },
    });
  };

  const privacy = (view: ReturnType<typeof settingsPage>) =>
    view.sections.find((s) => s.id === "privacy")?.rows.find((r) => r.id === "telemetry");

  it("shows Off and disables the row when the environment turns it off", () => {
    const row = privacy(page({ enabled: false, lockedBy: "env DO_NOT_TRACK" }));
    expect(row).toBeTruthy();
    expect(row!.enabled).toBe(false);
    expect(row!.options.map((o) => [o.id, o.active])).toEqual([
      ["on", false],
      ["off", true],
    ]);
    expect(row!.help).toContain("DO_NOT_TRACK");
  });

  it("shows On when the setting is on", () => {
    const row = privacy(page({ enabled: true, lockedBy: null }));
    expect(row!.options.map((o) => [o.id, o.active])).toEqual([
      ["on", true],
      ["off", false],
    ]);
  });
});
