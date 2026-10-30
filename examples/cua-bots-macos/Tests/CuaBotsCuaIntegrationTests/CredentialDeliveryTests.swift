// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Cua
import CuaBotsCore
import CuaBotsCua
import Foundation
import Testing

/// Opt-in: needs OrbStack and the cached `ghcr.io/trycua/linux:24.04` image.
/// Checks that a minted credential really lands inside the Bot's Space with
/// private permissions and works from there.
@MainActor
struct CredentialDeliveryTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CUA_BOTS_RUN_CREDENTIAL_DELIVERY"] == "1"))
  func aMintedCredentialWorksFromInsideTheBotSpace() async throws {
    let now = Date()
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.assign(
      botID: "alpha", spaceID: "local:shared", workingDirectory: "/bots/alpha",
      trustGroup: "team-a")
    var tokens = TokenStore()
    let admin = try tokens.issue(
      botID: "admin", trustGroup: "team-a", spaceID: nil, capabilities: [.manageRegistry],
      now: now, lifetime: 3600)
    var api = ServiceAPI(
      registry: registry, tokens: tokens,
      collaboration: CollaborationService(
        authorization: AuthorizationPolicy(registry: registry), registry: registry))
    api.now = { now }
    let server = ServiceServer(api: api)
    let port = try server.start()
    defer { server.stop() }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cua-bots-credential-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cua = try Cua.embedded(
      stateDir: root.appendingPathComponent("state").path,
      spacesHome: root.appendingPathComponent("spaces").path,
      teleportHome: root.appendingPathComponent("teleport").path)
    let engine = CuaEngine(cua: cua, endpoint: nil)
    engine.image = "ghcr.io/trycua/linux:24.04"
    let broker = try HTTPCredentialBroker(
      baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")), adminValue: admin)
    // The credential endpoint only mints for a Bot the registry knows.
    var bot = Bot(name: "alpha", owner: "integration-test")
    do {
      bot.spaceID = try await engine.provision(bot) { _ in }
      let space = try await engine.space(bot)
      let home = try await engine.home(bot, space)
      let access = try await engine.installServiceCredential(
        bot, broker: broker, apiURL: "http://host.docker.internal:\(port)", space: space,
        home: home)
      #expect(access.tokenFilePath == "\(home)/.cua-bots/credential")
      #expect(access.botID == bot.id)
      let modes = try await space.bash(
        command:
          "stat -c '%a %a' \(HarnessLaunch.quote(home + "/.cua-bots")) \(HarnessLaunch.quote(access.tokenFilePath))",
        timeoutMs: 10_000)
      #expect(modes.stdout.contains("700"))
      #expect(modes.stdout.contains("600"))
      let call = try await space.bash(
        command:
          "curl -sS -m 5 -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer $(cat \(HarnessLaunch.quote(access.tokenFilePath)))\" "
          + HarnessLaunch.quote("http://host.docker.internal:\(port)/v1/bots/alpha/messages"),
        timeoutMs: 15_000)
      #expect(call.stdout == "200")
      let anonymous = try await space.bash(
        command:
          "curl -sS -m 5 -o /dev/null -w '%{http_code}' "
          + HarnessLaunch.quote("http://host.docker.internal:\(port)/v1/bots/alpha/messages"),
        timeoutMs: 15_000)
      #expect(anonymous.stdout == "401")
    } catch {
      if let id = bot.spaceID { _ = try? await cua.spaces().delete(space: id) }
      throw error
    }
    if let id = bot.spaceID { _ = try? await cua.spaces().delete(space: id) }
  }
}
