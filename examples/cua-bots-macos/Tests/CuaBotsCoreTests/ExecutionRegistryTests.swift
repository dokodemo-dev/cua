// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct ExecutionRegistryTests {
  @Test func legacyMigrationNeverClaimsDeletionRights() throws {
    var registry = ExecutionRegistry()
    var bot = Bot(name: "Legacy")
    bot.spaceID = "local:bot-legacy"
    try registry.migrate(&bot)
    let first = registry
    try registry.migrate(&bot)
    #expect(registry == first)
    let target = try #require(bot.executionTargetID)
    #expect(registry.targets[target]?.kind == .local)
    let binding = try #require(registry.bindings["local:bot-legacy"])
    #expect(binding.managedByApp == false)
    #expect(binding.botIDs == [bot.id])
    #expect(try registry.detach(botID: bot.id, spaceID: binding.spaceID) == .preserve)
  }

  @Test func sharedBindingsRefuseDeletionAndUnsafeWorkspaces() throws {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: true))
    try registry.assign(
      botID: "first", spaceID: "local:shared", workingDirectory: "/home/cua/bots/first")
    #expect(throws: ExecutionRegistryError.overlappingWorkspace) {
      try registry.assign(
        botID: "second", spaceID: "local:shared", workingDirectory: "/home/cua/bots/first/child")
    }
    #expect(throws: ExecutionRegistryError.invalidWorkspace) {
      try registry.assign(
        botID: "second", spaceID: "local:shared", workingDirectory: "/home/cua/../first")
    }
    try registry.assign(
      botID: "second", spaceID: "local:shared", workingDirectory: "/home/cua/bots/second")
    #expect(try registry.detach(botID: "first", spaceID: "local:shared") == .preserve)
    #expect(registry.bindings["local:shared"]?.botIDs == ["second"])
    #expect(try registry.detach(botID: "second", spaceID: "local:shared") == .preserve)
  }

  @Test func exclusiveBindingRefusesAnotherBotAndOnlyOwnedSpaceCanBeDeleted() throws {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(spaceID: "local:owned", targetID: "local", mode: .exclusive, managedByApp: true))
    try registry.assign(
      botID: "first", spaceID: "local:owned", workingDirectory: "/home/cua/bots/first")
    #expect(throws: ExecutionRegistryError.exclusiveSpaceOccupied) {
      try registry.assign(
        botID: "second", spaceID: "local:owned", workingDirectory: "/home/cua/bots/second")
    }
    #expect(throws: ExecutionRegistryError.botNotAssigned) {
      _ = try registry.detach(botID: "second", spaceID: "local:owned")
    }
    #expect(try registry.detach(botID: "first", spaceID: "local:owned") == .deleteOwnedSpace)
  }

  @Test func screenLeaseRequiresMembershipAndCannotBeStolenOrReleasedByStaleHolder() throws {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false))
    try registry.assign(botID: "first", spaceID: "local:shared", workingDirectory: "/bots/first")
    try registry.assign(botID: "second", spaceID: "local:shared", workingDirectory: "/bots/second")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(throws: ExecutionRegistryError.botNotAssigned) {
      _ = try registry.acquireScreen(
        botID: "stranger", spaceID: "local:shared", now: now, duration: 10)
    }
    let first = try registry.acquireScreen(
      botID: "first", spaceID: "local:shared", now: now, duration: 10)
    #expect(throws: ExecutionRegistryError.screenBusy) {
      _ = try registry.acquireScreen(
        botID: "second", spaceID: "local:shared", now: now, duration: 10)
    }
    let second = try registry.acquireScreen(
      botID: "second", spaceID: "local:shared", now: now.addingTimeInterval(10), duration: 10)
    #expect(second.id != first.id)
    #expect(throws: ExecutionRegistryError.staleLease) {
      try registry.releaseScreen(botID: "first", spaceID: "local:shared", leaseID: first.id)
    }
    #expect(
      try registry.screenAllowed(
        botID: "second", spaceID: "local:shared", leaseID: second.id,
        now: now.addingTimeInterval(11)))
    #expect(
      try !registry.screenAllowed(
        botID: "second", spaceID: "local:shared", leaseID: second.id,
        now: now.addingTimeInterval(20)))
    try registry.releaseScreen(botID: "second", spaceID: "local:shared", leaseID: second.id)
  }

  @Test func targetAndBindingIdentityCannotBeOverwritten() throws {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    #expect(throws: ExecutionRegistryError.duplicateTarget) {
      try registry.addTarget(ExecutionTarget(id: "local", name: "Other", kind: .direct))
    }
    #expect(throws: ExecutionRegistryError.unknownTarget) {
      try registry.addBinding(
        SpaceBinding(
          spaceID: "direct:example", targetID: "missing", mode: .exclusive, managedByApp: false))
    }
    try registry.addBinding(
      SpaceBinding(spaceID: "local:owned", targetID: "local", mode: .exclusive, managedByApp: false)
    )
    #expect(throws: ExecutionRegistryError.duplicateBinding) {
      try registry.addBinding(
        SpaceBinding(
          spaceID: "local:owned", targetID: "local", mode: .exclusive, managedByApp: true))
    }
    #expect(
      try JSONDecoder().decode(ExecutionRegistry.self, from: JSONEncoder().encode(registry))
        == registry)
  }

  @Test func sharedSpaceRefusesAgentsFromAnotherTrustGroup() throws {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.assign(
      botID: "first", spaceID: "local:shared", workingDirectory: "/bots/first",
      trustGroup: "team-a")
    #expect(throws: ExecutionRegistryError.trustGroupMismatch) {
      try registry.assign(
        botID: "second", spaceID: "local:shared", workingDirectory: "/bots/second",
        trustGroup: "team-b")
    }
    #expect(registry.bindings["local:shared"]?.botIDs == ["first"])
    try registry.assign(
      botID: "second", spaceID: "local:shared", workingDirectory: "/bots/second",
      trustGroup: "team-a")
    #expect(registry.bindings["local:shared"]?.botIDs == ["first", "second"])
  }

  @Test func legacyBindingsDefaultToTheDefaultTrustGroup() throws {
    let json = """
      {"targets":{},"bindings":{"local:old":{"spaceID":"local:old",
      "targetID":"local","mode":"shared","managedByApp":false}}}
      """
    let registry = try JSONDecoder().decode(ExecutionRegistry.self, from: Data(json.utf8))
    #expect(registry.bindings["local:old"]?.trustGroup == "default")
    var bot = Bot(name: "Legacy")
    #expect(bot.effectiveTrustGroup == "default")
    bot.trustGroup = "team-a"
    #expect(bot.effectiveTrustGroup == "team-a")
    bot.trustGroup = ""
    #expect(bot.effectiveTrustGroup == "default")
  }

}
