// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct CollaborationTests {
  private let origin = Date(timeIntervalSince1970: 1_800_000_000)

  private func makeService(botIDs: [String] = ["alpha", "beta", "gamma", "delta", "epsilon"])
    throws -> CollaborationService
  {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    for (index, id) in botIDs.enumerated() {
      try registry.assign(
        botID: id, spaceID: "local:shared", workingDirectory: "/bots/\(id)", trustGroup: "team-a")
      _ = index
    }
    return CollaborationService(
      authorization: AuthorizationPolicy(registry: registry), registry: registry)
  }

  private func principal(_ id: String) -> BotPrincipal {
    BotPrincipal(
      botID: id, trustGroup: "team-a", capabilities: Set(Capability.allCases),
      spaceID: "local:shared", groupIDs: ["team-a"])
  }

  @Test func retryingWithTheSameKeyNeverCreatesASecondTask() throws {
    var service = try makeService()
    let first = try service.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Summarize",
      idempotencyKey: "req-1", now: origin, deadline: origin.addingTimeInterval(300))
    let second = try service.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Summarize",
      idempotencyKey: "req-1", now: origin, deadline: origin.addingTimeInterval(300))
    #expect(first.id == second.id)
    #expect(service.tasks.count == 1)
    #expect(throws: CollaborationError.idempotencyConflict) {
      try service.delegate(
        from: principal("alpha"), to: "gamma", spaceID: "local:shared", prompt: "Different",
        idempotencyKey: "req-1", now: origin, deadline: origin.addingTimeInterval(300))
    }
  }

  @Test func aBotNeverReappearsInItsOwnDelegationAncestry() throws {
    var service = try makeService()
    let first = try service.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Step 1",
      idempotencyKey: "a", now: origin, deadline: origin.addingTimeInterval(600))
    let second = try service.delegate(
      from: principal("beta"), to: "gamma", spaceID: "local:shared", prompt: "Step 2",
      parentID: first.id, idempotencyKey: "b", now: origin,
      deadline: origin.addingTimeInterval(600))
    #expect(second.depth == 2)
    #expect(throws: CollaborationError.delegationLoop) {
      try service.delegate(
        from: principal("gamma"), to: "alpha", spaceID: "local:shared", prompt: "Loop",
        parentID: second.id, idempotencyKey: "c", now: origin,
        deadline: origin.addingTimeInterval(600))
    }
    let third = try service.delegate(
      from: principal("gamma"), to: "delta", spaceID: "local:shared", prompt: "Step 3",
      parentID: second.id, idempotencyKey: "c2", now: origin,
      deadline: origin.addingTimeInterval(600))
    #expect(third.depth == 3)
    #expect(throws: CollaborationError.depthExceeded) {
      try service.delegate(
        from: principal("delta"), to: "epsilon", spaceID: "local:shared", prompt: "Too deep",
        parentID: third.id, idempotencyKey: "d", now: origin,
        deadline: origin.addingTimeInterval(600))
    }
  }

  @Test func globalAndPerBotConcurrencyAreBounded() throws {
    var service = try makeService()
    for (index, target) in ["beta", "gamma", "delta", "epsilon"].enumerated() {
      _ = try service.delegate(
        from: principal("alpha"), to: target, spaceID: "local:shared", prompt: "Work \(index)",
        idempotencyKey: "g\(index)", now: origin, deadline: origin.addingTimeInterval(600))
    }
    #expect(throws: CollaborationError.concurrencyLimit) {
      try service.delegate(
        from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Overflow",
        idempotencyKey: "over", now: origin, deadline: origin.addingTimeInterval(600))
    }
    var perBot = try makeService(botIDs: ["alpha", "beta", "gamma"])
    let first = try perBot.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "One",
      idempotencyKey: "p1", now: origin, deadline: origin.addingTimeInterval(600))
    try perBot.complete(taskID: first.id, result: "done", now: origin)
    _ = try perBot.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Two",
      idempotencyKey: "p2", now: origin, deadline: origin.addingTimeInterval(600))
    #expect(perBot.runningCount(for: "beta") == 1)
    #expect(perBot.runningCount == 1)
  }

  @Test func deadlinesAreClampedAndExpiredWorkIsNeverDelivered() throws {
    var service = try makeService()
    let parent = try service.delegate(
      from: principal("alpha"), to: "beta", spaceID: "local:shared", prompt: "Parent",
      idempotencyKey: "parent", now: origin, deadline: origin.addingTimeInterval(120))
    let child = try service.delegate(
      from: principal("beta"), to: "gamma", spaceID: "local:shared", prompt: "Child",
      parentID: parent.id, idempotencyKey: "child", now: origin,
      deadline: origin.addingTimeInterval(1800))
    #expect(child.deadline <= parent.deadline)
    try service.expire(now: origin.addingTimeInterval(121))
    #expect(service.task(parent.id)?.state == .expired)
    #expect(throws: CollaborationError.taskExpired) {
      try service.complete(taskID: parent.id, result: "late", now: origin.addingTimeInterval(122))
    }
    #expect(service.deliverableMessages(for: "alpha", now: origin.addingTimeInterval(122)).isEmpty)
  }

  @Test func artifactsAreOwnerScopedAndBounded() throws {
    var service = try makeService()
    let artifact = try service.registerArtifact(
      from: principal("alpha"), spaceID: "local:shared", name: "report.md",
      byteCount: 2048, sha256: String(repeating: "a", count: 64), now: origin)
    #expect(service.artifacts(for: "beta", now: origin) == [artifact])
    #expect(throws: AuthorizationError.artifactTooLarge) {
      try service.registerArtifact(
        from: principal("alpha"), spaceID: "local:shared", name: "huge.bin",
        byteCount: 8 * 1024 * 1024 + 1, sha256: String(repeating: "b", count: 64), now: origin)
    }
    #expect(throws: CollaborationError.invalidArtifactName) {
      try service.registerArtifact(
        from: principal("alpha"), spaceID: "local:shared", name: "../escaped.md",
        byteCount: 10, sha256: String(repeating: "c", count: 64), now: origin)
    }
    #expect(throws: AuthorizationError.notAMember) {
      let stranger = BotPrincipal(
        botID: "alpha", trustGroup: "team-a", capabilities: [.artifactsWrite],
        spaceID: "local:shared", groupIDs: ["team-a"])
      try service.registerArtifact(
        from: stranger, spaceID: "local:other", name: "x.md", byteCount: 1,
        sha256: String(repeating: "d", count: 64), now: origin)
    }
  }

  @Test func messagesOnlyReachCurrentSpaceMembers() throws {
    var service = try makeService()
    let note = try service.post(
      from: principal("alpha"), spaceID: "local:shared", body: "Standup at 10",
      idempotencyKey: "note-1", now: origin)
    #expect(service.deliverableMessages(for: "beta", now: origin).map(\.id) == [note.id])
    #expect(service.deliverableMessages(for: "alpha", now: origin).isEmpty)
    #expect(throws: CollaborationError.notAMember) {
      try service.post(
        from: principal("alpha"), spaceID: "local:nowhere", body: "Leak",
        idempotencyKey: "note-2", now: origin)
    }
    let direct = try service.post(
      from: principal("alpha"), spaceID: "local:shared", body: "Ping", to: "beta",
      idempotencyKey: "note-3", now: origin)
    #expect(service.deliverableMessages(for: "gamma", now: origin).map(\.id) == [note.id])
    #expect(
      service.deliverableMessages(for: "beta", now: origin).map(\.id) == [note.id, direct.id])
  }
}
