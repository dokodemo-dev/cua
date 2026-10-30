// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

@MainActor
struct ReconnectTests {
  @Test func completedTurnsAreNotReplayedAfterStoreRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = LocalVolume(root: root.appendingPathComponent("volume"))
    let data = root.appendingPathComponent("data")
    let engine = ReplayEngine()
    let store = BotStore(volume: volume, dataDirectory: data, engine: engine)
    let bot = await store.createBot(
      name: "Restart", avatar: .default(for: "Restart"), harness: .pi, placement: .local)
    store.disconnect()
    _ = await store.pollOnce(bot.id)
    let before = store.messages(for: bot.id)
    let restored = BotStore(volume: volume, dataDirectory: data, engine: engine)
    defer { restored.disconnect() }
    _ = await restored.pollOnce(bot.id)
    #expect(restored.messages(for: bot.id).count == before.count)
    #expect(engine.cursors.last == UInt64(engine.events.count))
    #expect(restored.bot(bot.id)?.runID == bot.runID)
    #expect(engine.starts == 1)
  }

  @Test func partialTurnAndBusyStateSurviveRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = LocalVolume(root: root.appendingPathComponent("volume"))
    let data = root.appendingPathComponent("data")
    let engine = ReplayEngine()
    engine.events = [.assistantDelta(turn: 1, text: "Partial")]
    let store = BotStore(volume: volume, dataDirectory: data, engine: engine)
    let bot = await store.createBot(
      name: "Partial", avatar: .default(for: "Partial"), harness: .pi, placement: .local)
    store.disconnect()
    _ = await store.pollOnce(bot.id)
    let restored = BotStore(volume: volume, dataDirectory: data, engine: engine)
    defer { restored.disconnect() }
    #expect(restored.isBusy(bot.id))
    engine.events.append(.assistantDelta(turn: 1, text: " answer"))
    engine.events.append(.turnEnded(turn: 1))
    _ = await restored.pollOnce(bot.id)
    #expect(!restored.isBusy(bot.id))
    #expect(restored.messages(for: bot.id).filter { $0.text == "Partial answer" }.count == 1)
  }

  @Test func recreatedBotDoesNotInheritDeletedRunsCursor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = ReplayEngine()
    let store = BotStore(
      volume: LocalVolume(root: root.appendingPathComponent("volume")),
      dataDirectory: root.appendingPathComponent("data"), engine: engine)
    defer { store.disconnect() }
    let original = await store.createBot(
      name: "Recreated", avatar: .default(for: "Recreated"), harness: .pi, placement: .local)
    store.disconnect()
    _ = await store.pollOnce(original.id)
    await store.reset(original.id)
    let recreated = await store.createBot(
      name: "Recreated", avatar: .default(for: "Recreated"), harness: .pi, placement: .local)
    store.disconnect()
    _ = await store.pollOnce(recreated.id)
    #expect(store.messages(for: recreated.id).filter { $0.text == "Answer" }.count == 1)
    #expect(!store.isBusy(recreated.id))
  }
}

@MainActor
private final class ReplayEngine: BotEngine {
  var events: [EngineUpdate] = [.assistant(turn: 1, text: "Answer"), .turnEnded(turn: 1)]
  var cursors: [UInt64] = []
  var starts = 0
  func provision(_ bot: Bot, progress: @escaping @MainActor (EnginePhase) -> Void) async throws
    -> String
  { "local:\(bot.spaceName)" }
  func start(_ bot: Bot, volume: VolumeStore, prompt: String) async throws -> String {
    starts += 1
    return "persistent-run"
  }
  func poll(_ bot: Bot, cursor: UInt64) async throws -> (updates: [EngineUpdate], cursor: UInt64) {
    cursors.append(cursor)
    return (Array(events.dropFirst(Int(cursor))), UInt64(events.count))
  }
  func send(_ bot: Bot, text: String) async throws {}
  func push(_ bot: Bot, volume: VolumeStore) async throws {}
  func checkpoint(_ bot: Bot, volume: VolumeStore) async throws {}
  func interrupt(_ bot: Bot) async throws {}
  func pause(_ bot: Bot) async throws {}
  func resume(_ bot: Bot) async throws {}
  func stop(_ bot: Bot) async throws {}
  func reset(_ bot: Bot) async throws {}
}
