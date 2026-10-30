// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Cua
import CuaBotsCore
import CuaBotsCua
import Foundation
import Testing

/// Opt-in: needs OrbStack, the cached `ghcr.io/trycua/linux:24.04` image, and a
/// test-only model placeholder. Run with `DO_NOT_TRACK=1 CUA_TELEMETRY=0` so the
/// SDK sends nothing. The first turn may install the harness inside the guest,
/// so it waits up to four minutes before failing.
@MainActor
struct SharedSpaceAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CUA_BOTS_RUN_SHARED_SPACE"] == "1"))
  func interruptingOneBotLeavesTheSharedSpaceUsable() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["OPENAI_API_KEY"]?.hasPrefix("test-") == true else {
      Issue.record("Set OPENAI_API_KEY to a non-production test placeholder beginning with test-")
      return
    }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cua-bots-shared-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cua = try Cua.embedded(
      stateDir: root.appendingPathComponent("state").path,
      spacesHome: root.appendingPathComponent("spaces").path,
      teleportHome: root.appendingPathComponent("teleport").path)
    let engine = CuaEngine(
      cua: cua,
      endpoint: ModelEndpoint(
        baseURL: "http://127.0.0.1:18788/v1", model: "test-model",
        keyVariables: ["OPENAI_API_KEY"]))
    engine.image = "ghcr.io/trycua/linux:24.04"
    let helper = CuaEngineIntegrationTests()
    let volume = LocalVolume(root: root.appendingPathComponent("volume"))
    var first = Bot(name: "shared-a-\(UUID().uuidString)", owner: "integration-test")
    var second = Bot(name: "shared-b-\(UUID().uuidString)", owner: "integration-test")
    var shared = false
    do {
      first.spaceID = try await engine.provision(first) { _ in }
      second.spaceID = first.spaceID
      shared = true
      let space = try await engine.space(first)
      try await helper.startMock(in: space)

      let firstHome = try await engine.home(first, space)
      let secondHome = try await engine.home(second, space)
      #expect(firstHome != secondHome)
      #expect(firstHome.hasPrefix("/home/cua/bots/"))
      #expect(secondHome.hasPrefix("/home/cua/bots/"))

      first.runID = try await engine.start(first, volume: volume, prompt: "Say hello.")
      let firstReply = try await helper.waitForReply(
        engine: engine, bot: first, space: space, cursor: 0, attempts: 2400)
      #expect(firstReply.text.contains("CuaEngine mock reply."))

      second.runID = try await engine.start(second, volume: volume, prompt: "Say hello.")
      let secondReply = try await helper.waitForReply(
        engine: engine, bot: second, space: space, cursor: 0, attempts: 600)
      #expect(secondReply.text.contains("CuaEngine mock reply."))
      #expect(first.runID != second.runID)

      // Pausing one member of a shared Space must not suspend the Space.
      try await engine.interrupt(first)
      try await engine.send(second, text: "Still there?")
      let afterInterrupt = try await helper.waitForReply(
        engine: engine, bot: second, space: space, cursor: secondReply.cursor)
      #expect(afterInterrupt.text.contains("CuaEngine mock reply."))

      try await engine.stop(first)
      let alive = try await space.bash(command: "printf shared-alive", timeoutMs: 10_000)
      #expect(alive.exitCode == 0)
      #expect(alive.stdout == "shared-alive")
      try await engine.send(second, text: "One more.")
      let afterStop = try await helper.waitForReply(
        engine: engine, bot: second, space: space, cursor: afterInterrupt.cursor)
      #expect(afterStop.text.contains("CuaEngine mock reply."))
    } catch {
      if let run = second.runID { _ = try? await engine.space(second).agentStop(runId: run) }
      if let run = first.runID { _ = try? await engine.space(first).agentStop(runId: run) }
      if let id = first.spaceID, shared { _ = try? await cua.spaces().delete(space: id) }
      throw error
    }
    if let run = second.runID { _ = try? await engine.space(second).agentStop(runId: run) }
    if let run = first.runID { _ = try? await engine.space(first).agentStop(runId: run) }
    if let id = first.spaceID { _ = try? await cua.spaces().delete(space: id) }
  }
}
