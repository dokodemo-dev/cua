// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct LaunchTests {
  @Test func piModelProviderAndProfileReachLaunch() throws {
    var runtime = BotRuntime()
    runtime.model = "test-model"
    runtime.provider = "test-provider"
    runtime.piAgentDirectory = "/opt/bot-profile"
    runtime.workingDirectory = "/srv/bot's workspace"
    runtime.systemPrompt = "Use the project's tools."
    let launch = try HarnessLaunch(
      bot: Bot(name: "Test", runtime: runtime), home: "/home/cua/bots/test")
    #expect(launch.cwd == runtime.workingDirectory)
    #expect(launch.model == runtime.model)
    #expect(launch.environment["PI_CODING_AGENT_DIR"] == runtime.piAgentDirectory)
    let data = try #require(launch.files["\(launch.cwd)/.pi/settings.json"])
    let settings = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(settings["defaultProvider"] == runtime.provider)
    #expect(settings["defaultModel"] == runtime.model)
    #expect(
      launch.files["\(launch.cwd)/.pi/APPEND_SYSTEM.md"]
        == Data((HarnessLaunch.promptHeader + runtime.systemPrompt).utf8))
    #expect(HarnessLaunch.quote("a'b") == "'a'\\''b'")
  }

  @Test func isolatedDefaultAndEndpointConflict() throws {
    var bot = Bot(name: "Test")
    let launch = try HarnessLaunch(bot: bot, home: "/bots/test", endpointModel: "fallback")
    #expect(launch.environment["PI_CODING_AGENT_DIR"] == "/bots/test/.pi-agent")
    #expect(launch.model == "fallback")
    let endpoint = try HarnessLaunch(bot: bot, home: "/bots/test", customEndpoint: true)
    #expect(endpoint.environment["PI_CODING_AGENT_DIR"] == nil)
    bot.runtime = BotRuntime()
    bot.runtime?.piAgentDirectory = "/existing/profile"
    #expect(throws: HarnessLaunch.LaunchError.self) {
      try HarnessLaunch(bot: bot, home: "/bots/test", customEndpoint: true)
    }
    bot.harness = .codex
    let codex = try HarnessLaunch(bot: bot, home: "/bots/test")
    #expect(codex.environment.isEmpty)
    #expect(codex.files.isEmpty)
  }

  @Test func existingResourcesSurviveModelChanges() throws {
    let merged = try HarnessLaunch.mergeSettings(
      existing: Data(
        """
        {"extensions":["./tools.ts"],"skills":["./skills"],"defaultModel":"old"}
        """.utf8), managed: Data("{\"defaultProvider\":\"test-provider\"}".utf8))
    let settings = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
    #expect(settings["extensions"] as? [String] == ["./tools.ts"])
    #expect(settings["skills"] as? [String] == ["./skills"])
    #expect(settings["defaultModel"] == nil)
    #expect(settings["defaultProvider"] as? String == "test-provider")
    #expect(throws: (any Error).self) {
      try HarnessLaunch.mergeSettings(existing: Data("broken".utf8), managed: Data("{}".utf8))
    }
  }

  @Test func serviceAccessOnlyNamesTheURLAndTheFilePath() throws {
    let access = BotServiceAccess(
      apiURL: "http://host.docker.internal:9123",
      tokenFilePath: "/home/cua/bots/test/.service/credential",
      botID: "test")
    let launch = try HarnessLaunch(
      bot: Bot(name: "Test"), home: "/home/cua/bots/test", serviceAccess: access)
    #expect(launch.environment["CUA_BOTS_API_URL"] == access.apiURL)
    #expect(launch.environment["CUA_BOTS_TOKEN_FILE"] == access.tokenFilePath)
    #expect(launch.environment["CUA_BOTS_ID"] == access.botID)
    let without = try HarnessLaunch(bot: Bot(name: "Test"), home: "/home/cua/bots/test")
    #expect(without.environment["CUA_BOTS_API_URL"] == nil)
    #expect(without.serviceAccess == nil)
    // The Bot record itself has no place for a credential.
    let encoded = String(decoding: try JSONEncoder().encode(Bot(name: "Test")), as: UTF8.self)
    #expect(!encoded.lowercased().contains("credential"))
  }
}
