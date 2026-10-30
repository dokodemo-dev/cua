// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

@MainActor
struct ExecutionStoreTests {
  @Test func assignedSharedSpaceNeverGetsResetOrSuspended() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = ScriptedEngine()
    let store = BotStore(
      volume: LocalVolume(root: root.appendingPathComponent("volume")),
      dataDirectory: root.appendingPathComponent("data"), engine: engine)
    defer { store.disconnect() }
    let first = await store.createBot(
      name: "First", avatar: .default(for: "First"), harness: .pi, placement: .local)
    _ = await store.pollOnce(first.id)
    let second = await store.createBot(
      name: "Second", avatar: .default(for: "Second"), harness: .pi, placement: .local)
    _ = await store.pollOnce(second.id)
    try store.registerTarget(ExecutionTarget(id: "existing", name: "Existing", kind: .local))
    try store.registerBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "existing", mode: .shared, managedByApp: false))
    #expect(await store.assign(first.id, to: "local:shared", workingDirectory: "/bots/first"))
    #expect(await store.assign(second.id, to: "local:shared", workingDirectory: "/bots/second"))
    #expect(store.bot(first.id)?.runID == nil)
    #expect(engine.resetCount == 0)
    await store.send(first.id, "Start in shared Space")
    _ = await store.pollOnce(first.id)
    await store.pause(first.id)
    #expect(engine.paused == false)
    await store.resume(first.id)
    #expect(store.bot(second.id)?.spaceID == "local:shared")
    await store.reset(first.id)
    #expect(engine.resetCount == 0)
    #expect(store.bot(first.id) == nil)
    #expect(store.executions.bindings["local:shared"]?.botIDs == [second.id])
    let restored = BotStore(volume: store.volume, dataDirectory: store.dataDirectory)
    #expect(restored.bot(second.id)?.executionTargetID == "existing")
    #expect(restored.executions == store.executions)
  }

  @Test func assignmentFailureKeepsExistingRunAndRegistry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = ScriptedEngine()
    let store = BotStore(
      volume: LocalVolume(root: root.appendingPathComponent("volume")),
      dataDirectory: root.appendingPathComponent("data"), engine: engine)
    defer { store.disconnect() }
    let bot = await store.createBot(
      name: "First", avatar: .default(for: "First"), harness: .pi, placement: .local)
    _ = await store.pollOnce(bot.id)
    try store.registerTarget(ExecutionTarget(id: "existing", name: "Existing", kind: .direct))
    try store.registerBinding(
      SpaceBinding(
        spaceID: "direct:shared", targetID: "existing", mode: .shared, managedByApp: false))
    let before = store.executions
    engine.refuseStop = true
    #expect(
      await store.assign(bot.id, to: "direct:shared", workingDirectory: "/bots/first") == false)
    #expect(store.bot(bot.id)?.runID == bot.runID)
    #expect(store.bot(bot.id)?.spaceID == bot.spaceID)
    #expect(store.executions == before)
  }

  @Test func creatingABotInAnExistingSpaceSkipsProvisioningAndDeletesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = ScriptedEngine()
    let store = BotStore(
      volume: LocalVolume(root: root.appendingPathComponent("volume")),
      dataDirectory: root.appendingPathComponent("data"), engine: engine)
    defer { store.disconnect() }
    let assignment = ExistingSpaceAssignment(
      spaceID: "local:team", targetID: "team-mac", targetName: "Team Mac", trustGroup: "team-a",
      workingDirectory: "/home/cua/bots/guest")
    let bot = await store.createBot(
      name: "Guest", avatar: .default(for: "Guest"), harness: .pi, placement: .local,
      existingSpace: assignment)
    #expect(engine.provisionCount == 0)
    #expect(bot.spaceID == "local:team")
    #expect(bot.executionTargetID == "team-mac")
    #expect(bot.runtime?.workingDirectory == "/home/cua/bots/guest")
    #expect(bot.trustGroup == "team-a")
    let binding = try #require(store.executions.bindings["local:team"])
    #expect(binding.mode == .shared)
    #expect(binding.managedByApp == false)
    #expect(binding.trustGroup == "team-a")
    #expect(binding.botIDs == [bot.id])
    await store.reset(bot.id)
    #expect(engine.resetCount == 0)
    #expect(store.executions.bindings["local:team"]?.botIDs.isEmpty == true)

    let rejected = await store.createBot(
      name: "Intruder", avatar: .default(for: "Intruder"), harness: .pi, placement: .local,
      existingSpace: ExistingSpaceAssignment(
        spaceID: "local:team", targetID: "team-mac", targetName: "Team Mac",
        trustGroup: "team-b", workingDirectory: "/home/cua/bots/intruder"))
    #expect(rejected.spaceID == nil)
    #expect(store.bot(rejected.id)?.spaceID == nil)
    #expect(store.executions.bindings["local:team"]?.botIDs.isEmpty == true)
    #expect(store.lastError != nil)

    let defaulted = await store.createBot(
      name: "Defaulted", avatar: .default(for: "Defaulted"), harness: .pi, placement: .local,
      existingSpace: ExistingSpaceAssignment(
        spaceID: "local:team", targetID: "team-mac", targetName: "Team Mac",
        trustGroup: "team-a", workingDirectory: "  "))
    #expect(defaulted.runtime?.workingDirectory == "/home/cua/bots/\(defaulted.id)")
  }
}
