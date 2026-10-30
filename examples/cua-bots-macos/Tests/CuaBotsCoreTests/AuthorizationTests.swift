// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct AuthorizationTests {
  private func registry() throws -> ExecutionRegistry {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:other", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-b"))
    try registry.assign(
      botID: "first", spaceID: "local:shared", workingDirectory: "/bots/first", trustGroup: "team-a"
    )
    try registry.assign(
      botID: "second", spaceID: "local:shared", workingDirectory: "/bots/second",
      trustGroup: "team-a")
    try registry.assign(
      botID: "stranger", spaceID: "local:other", workingDirectory: "/bots/stranger",
      trustGroup: "team-b")
    return registry
  }

  private func principal(_ capabilities: Set<Capability>, space: String? = "local:shared")
    -> BotPrincipal
  {
    BotPrincipal(
      botID: "first", trustGroup: "team-a", capabilities: capabilities,
      spaceID: space, groupIDs: ["team-a"])
  }

  @Test func readingASharedSpaceNeedsMembershipAndCapability() throws {
    let policy = AuthorizationPolicy(registry: try registry())
    try policy.check(principal([.spacesRead]), .readSpace(spaceID: "local:shared"))
    #expect(throws: AuthorizationError.missingCapability) {
      try policy.check(principal([]), .readSpace(spaceID: "local:shared"))
    }
    #expect(throws: AuthorizationError.notAMember) {
      try policy.check(principal([.spacesRead]), .readSpace(spaceID: "local:other"))
    }
    #expect(throws: AuthorizationError.notAMember) {
      try policy.check(principal([.spacesRead], space: nil), .readSpace(spaceID: "local:shared"))
    }
  }

  @Test func screenControlNeedsItsOwnCapabilityAndAnActiveLease() throws {
    let policy = AuthorizationPolicy(registry: try registry())
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(throws: AuthorizationError.missingCapability) {
      try policy.check(
        principal([.spacesRead]), .controlScreen(spaceID: "local:shared", leaseID: nil), now: now)
    }
    #expect(throws: AuthorizationError.screenLeaseRequired) {
      try policy.check(
        principal([.screenControl]), .controlScreen(spaceID: "local:shared", leaseID: nil), now: now
      )
    }
    var leased = try registry()
    let lease = try leased.acquireScreen(
      botID: "first", spaceID: "local:shared", now: now, duration: 60)
    let leasing = AuthorizationPolicy(registry: leased)
    try leasing.check(
      principal([.screenControl]), .controlScreen(spaceID: "local:shared", leaseID: lease.id),
      now: now)
    #expect(throws: AuthorizationError.screenLeaseRequired) {
      try leasing.check(
        principal([.screenControl]), .controlScreen(spaceID: "local:shared", leaseID: UUID()),
        now: now)
    }
  }

  @Test func artifactsStayInsideTheSpaceAndWithinTheSizeCap() throws {
    let policy = AuthorizationPolicy(registry: try registry())
    try policy.check(
      principal([.artifactsWrite]),
      .writeArtifact(spaceID: "local:shared", ownerBotID: "first", byteCount: 8 * 1024 * 1024))
    #expect(throws: AuthorizationError.artifactTooLarge) {
      try policy.check(
        principal([.artifactsWrite]),
        .writeArtifact(spaceID: "local:shared", ownerBotID: "first", byteCount: 8 * 1024 * 1024 + 1)
      )
    }
    #expect(throws: AuthorizationError.crossBotAccess) {
      try policy.check(
        principal([.artifactsWrite]),
        .writeArtifact(spaceID: "local:shared", ownerBotID: "second", byteCount: 10))
    }
    try policy.check(
      principal([.artifactsRead]),
      .readArtifact(spaceID: "local:shared", ownerBotID: "second"))
    #expect(throws: AuthorizationError.notAMember) {
      try policy.check(
        principal([.artifactsRead]),
        .readArtifact(spaceID: "local:other", ownerBotID: "stranger"))
    }
  }

  @Test func delegationNeedsSameGroupExplicitRecipientAndCapability() throws {
    let policy = AuthorizationPolicy(registry: try registry())
    try policy.check(
      principal([.delegate]),
      .delegate(
        toBotID: "second", groupID: "team-a", depth: 1, deadline: Date().addingTimeInterval(60)))
    #expect(throws: AuthorizationError.crossTrustGroup) {
      try policy.check(
        principal([.delegate]),
        .delegate(
          toBotID: "stranger", groupID: "team-b", depth: 1,
          deadline: Date().addingTimeInterval(60)))
    }
    #expect(throws: AuthorizationError.delegationDepthExceeded) {
      try policy.check(
        principal([.delegate]),
        .delegate(
          toBotID: "second", groupID: "team-a", depth: 4, deadline: Date().addingTimeInterval(60)))
    }
    #expect(throws: AuthorizationError.deadlineTooLong) {
      try policy.check(
        principal([.delegate]),
        .delegate(
          toBotID: "second", groupID: "team-a", depth: 1,
          deadline: Date().addingTimeInterval(1801)))
    }
    #expect(throws: AuthorizationError.selfDelegation) {
      try policy.check(
        principal([.delegate]),
        .delegate(
          toBotID: "first", groupID: "team-a", depth: 1, deadline: Date().addingTimeInterval(60)))
    }
  }

  @Test func managementIsLoopbackOnlyAndNeedsTheRegistryCapability() throws {
    let policy = AuthorizationPolicy(registry: try registry())
    try policy.check(
      principal([.manageRegistry], space: nil), .manageRegistry(remoteAddress: "127.0.0.1"))
    try policy.check(
      principal([.manageRegistry], space: nil), .manageRegistry(remoteAddress: "::1"))
    #expect(throws: AuthorizationError.managementNotLocal) {
      try policy.check(
        principal([.manageRegistry], space: nil), .manageRegistry(remoteAddress: "198.51.100.7"))
    }
    #expect(throws: AuthorizationError.missingCapability) {
      try policy.check(
        principal([.spacesRead], space: nil), .manageRegistry(remoteAddress: "127.0.0.1"))
    }
  }
}
