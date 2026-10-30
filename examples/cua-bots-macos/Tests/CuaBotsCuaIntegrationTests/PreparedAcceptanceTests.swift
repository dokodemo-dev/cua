// SPDX-License-Identifier: FSL-1.1-MIT
import Cua
import CuaBotsCore
import CuaBotsCua
import Foundation
import Testing

/// Uses only a disposable Space prepared by the Phase 1 acceptance procedure.
@MainActor
struct PreparedAcceptanceTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CUA_BOTS_RUN_PREPARED_ACCEPTANCE"] == "1"))
  func piResourcesAndBothHarnessesReconnect() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let home = env["HOME"], home.hasPrefix("/tmp/cua-phase1-guest."),
      let spaceID = env["CUA_PHASE1_SPACE"], spaceID.hasPrefix("local:phase1-"),
      env["CUA_TELEMETRY"] == "0", env["CUA_TELEMETRY_FORBID_NETWORK"] == "1",
      env["OPENAI_API_KEY"]?.hasPrefix("test-") == true
    else { throw AcceptanceError.unsafeEnvironment }

    for harness in [Harness.pi, .codex] {
      let root = URL(fileURLWithPath: home).appendingPathComponent(
        "acceptance-\(harness.id)-\(UUID().uuidString)")
      let volume = LocalVolume(root: root.appendingPathComponent("volume"))
      let data = root.appendingPathComponent("data")
      let endpoint =
        harness == .codex
        ? ModelEndpoint(
          baseURL: "http://host.docker.internal:18789/v1", model: "test-model",
          keyVariables: ["OPENAI_API_KEY"]) : nil
      let engine = CuaEngine(cua: try Cua.embedded(), endpoint: endpoint)
      var runtime = BotRuntime()
      runtime.model = "test-model"
      runtime.workingDirectory = harness == .pi ? "/home/cua/phase1-pi" : "/tmp/phase1-codex-store"
      if harness == .pi {
        runtime.provider = "phase1"
        runtime.piAgentDirectory = "/home/cua/phase1-profile"
      }
      var bot = Bot(
        name: "acceptance-\(harness.id)", owner: "integration-test", harness: harness,
        runtime: runtime)
      bot.spaceID = spaceID
      try volume.writeJSON(bot, VolumeLayout.identity(bot.id))
      let store = BotStore(volume: volume, dataDirectory: data, engine: engine)
      let firstPrompt =
        harness == .pi ? "/skill:phase1-probe" : "mock: say PHASE1_CODEX_STORE_FIRST"
      do {
        await store.send(bot.id, firstPrompt)
        try await waitForIdle(store, bot.id)
        store.disconnect()
        let firstText = store.messages(for: bot.id).map(\.text).joined(separator: "\n")
        try #require(
          firstText.contains(harness == .pi ? "PHASE1_SKILL_LOADED" : "PHASE1_CODEX_STORE_FIRST"))
        if harness == .pi {
          let space = try await engine.space(try #require(store.bot(bot.id)))
          let marker = try await space.bash(
            command: "test -f /home/cua/phase1-pi/phase1-extension-executed", timeoutMs: 5_000)
          try #require(marker.exitCode == 0)
        }
        let runID = try #require(store.bot(bot.id)?.runID)
        let count = store.messages(for: bot.id).count
        let restoredEngine = CuaEngine(cua: try Cua.embedded(), endpoint: endpoint)
        let restored = BotStore(volume: volume, dataDirectory: data, engine: restoredEngine)
        defer { restored.disconnect() }
        #expect(restored.bot(bot.id)?.runtime == runtime)
        #expect(restored.bot(bot.id)?.spaceID == spaceID)
        _ = await restored.pollOnce(bot.id)
        #expect(restored.messages(for: bot.id).count == count)
        await restored.send(bot.id, "mock: say PHASE1_STORE_RECONNECTED")
        try await waitForIdle(restored, bot.id)
        #expect(restored.bot(bot.id)?.runID == runID)
        try #require(
          restored.messages(for: bot.id).contains {
            $0.role == .bot && $0.text.contains("PHASE1_STORE_RECONNECTED")
          })
        try await restoredEngine.stop(try #require(restored.bot(bot.id)))
        print("Phase 1 accepted: \(harness.id), same Run after store/engine reconstruction")
      } catch {
        store.disconnect()
        if let live = store.bot(bot.id) { try? await engine.stop(live) }
        throw error
      }
    }
  }

  private func waitForIdle(_ store: BotStore, _ id: String) async throws {
    for _ in 0..<600 {
      _ = await store.pollOnce(id)
      if store.bot(id)?.mood == .error { throw AcceptanceError.agentFailed }
      if !store.isBusy(id) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw AcceptanceError.timedOut
  }
  private enum AcceptanceError: Error { case unsafeEnvironment, agentFailed, timedOut }
}
