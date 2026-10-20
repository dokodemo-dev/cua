// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

@MainActor
struct RuntimeStoreTests {
  @Test func switchPreservesSpaceAndPersistsConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = ScriptedEngine()
    let volume = LocalVolume(root: root.appendingPathComponent("volume"))
    let store = BotStore(
      volume: volume, dataDirectory: root.appendingPathComponent("data"), engine: engine)
    let bot = await store.createBot(
      name: "Test", avatar: .default(for: "Test"), harness: .pi, placement: .local)
    defer { store.disconnect() }
    var runtime = BotRuntime()
    runtime.model = "test-model"
    runtime.provider = "test-provider"
    #expect(await store.configure(bot.id, harness: .codex, runtime: runtime) == false)
    _ = await store.pollOnce(bot.id)
    await store.send(bot.id, "Continue the Pi session")
    #expect(engine.starts.count == 1)
    #expect(store.bot(bot.id)?.runID == "run-1")
    _ = await store.pollOnce(bot.id)
    engine.refuseStop = true
    #expect(await store.configure(bot.id, harness: .codex, runtime: runtime) == false)
    #expect(store.bot(bot.id)?.harness == .pi)
    #expect(store.bot(bot.id)?.runID == bot.runID)
    engine.refuseStop = false
    #expect(await store.configure(bot.id, harness: .codex, runtime: runtime))
    #expect(engine.stopped == ["run-1"])
    #expect(engine.resetCount == 0)
    #expect(store.bot(bot.id)?.spaceID == bot.spaceID)
    #expect(store.bot(bot.id)?.runID == nil)
    await store.send(bot.id, "Continue")
    #expect(engine.starts.last?.harness == .codex)
    #expect(engine.starts.last?.runtime == runtime)
    #expect(store.bot(bot.id)?.runID == "run-2")
    _ = await store.pollOnce(bot.id)
    let restored = BotStore(volume: volume, dataDirectory: root.appendingPathComponent("data"))
    #expect(restored.bot(bot.id)?.runtime == runtime)
    #expect(restored.bot(bot.id)?.harness == .codex)
    #expect(restored.bot(bot.id)?.runID == "run-2")
  }
}
