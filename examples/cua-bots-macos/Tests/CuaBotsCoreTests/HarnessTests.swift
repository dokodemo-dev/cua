// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct HarnessTests {
  @Test func defaultsAndLegacyEncoding() throws {
    #expect(Bot(name: "Test").harness == .pi)
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    for id in ["hermes", "openclaw", "claude-code", "openai-codex", "future-harness"] {
      var json = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(Bot(name: "Test"))) as? [String: Any])
      json["harness"] = id
      json.removeValue(forKey: "runtime")
      let bot = try decoder.decode(Bot.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(bot.harness.rawValue == id)
      #expect(bot.runtime == nil)
      #expect(try decoder.decode(Bot.self, from: encoder.encode(bot)) == bot)
    }
  }

  @Test func catalogUsesSDKAndFallsBackOffline() {
    let entries = HarnessDescriptor.catalog(
      json: """
        [{"id":"pi","name":"Pi"},{"id":"opencode","name":"OpenCode"},{"id":"pi","name":"Duplicate"}]
        """)
    #expect(entries.map(\.id) == ["pi", "opencode"])
    #expect(HarnessDescriptor.catalog(json: "invalid").contains { $0.id == "pi" })
  }

  @Test func runtimeRoundTripAndPaths() throws {
    var runtime = BotRuntime()
    runtime.model = "test-model"
    runtime.provider = "test-provider"
    runtime.workingDirectory = "/srv/bot's work"
    runtime.piAgentDirectory = "/srv/pi-agent"
    runtime.systemPrompt = "Be concise."
    try runtime.validate()
    let bot = Bot(name: "Test", runtime: runtime)
    #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot)).runtime == runtime)
    for invalid in ["relative", "/srv/../other", "/srv/\0"] {
      runtime.workingDirectory = invalid
      #expect(throws: BotRuntime.RuntimeError.self) { try runtime.validate() }
    }
  }
}
