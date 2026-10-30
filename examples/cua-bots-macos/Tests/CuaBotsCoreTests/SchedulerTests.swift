// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct SchedulerTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func state(owner: String = "service-a") -> SchedulerState {
    SchedulerState(ownerID: owner)
  }

  @Test func aDueSlotIsClaimedExactlyOnce() throws {
    var scheduler = state()
    let job = try scheduler.addJob(
      botID: "alpha", title: "Digest", prompt: "Summarize the inbox", cadence: 3600,
      startAt: t0.addingTimeInterval(60))
    #expect(try scheduler.acquireLease(now: t0, duration: 600))
    #expect(try scheduler.claimDue(now: t0, limit: 10).isEmpty)
    let claims = try scheduler.claimDue(now: t0.addingTimeInterval(60), limit: 10)
    #expect(claims.map(\.deliveryKey) == ["\(job)@2027-01-15T08:01:00Z"])
    #expect(try scheduler.claimDue(now: t0.addingTimeInterval(60), limit: 10).isEmpty)
    try scheduler.markDelivered(claims[0].deliveryKey, at: t0.addingTimeInterval(61))
    #expect(scheduler.delivery(claims[0].deliveryKey)?.state == .delivered)
    #expect(try scheduler.claimDue(now: t0.addingTimeInterval(62), limit: 10).isEmpty)
    #expect(scheduler.job(job)?.nextRunAt == t0.addingTimeInterval(3660))
  }

  @Test func restartKeepsDeliveriesAndNeverDoubleSendsTheSameSlot() throws {
    var scheduler = state()
    let job = try scheduler.addJob(
      botID: "alpha", title: "Digest", prompt: "Summarize", cadence: 600,
      startAt: t0.addingTimeInterval(10))
    #expect(try scheduler.acquireLease(now: t0, duration: 600))
    let claim = try #require(try scheduler.claimDue(now: t0.addingTimeInterval(10), limit: 1).first)
    try scheduler.markDelivered(claim.deliveryKey, at: t0.addingTimeInterval(11))
    let saved = try JSONEncoder().encode(scheduler)
    var restored = try JSONDecoder().decode(SchedulerState.self, from: saved)
    #expect(restored.job(job)?.nextRunAt == scheduler.job(job)?.nextRunAt)
    #expect(try restored.claimDue(now: t0.addingTimeInterval(11), limit: 10).isEmpty)
    #expect(restored.unresolvedDeliveries().isEmpty)
  }

  @Test func aCrashLeavesWorkUnconfirmedAndItIsNotResentAutomatically() throws {
    var scheduler = state()
    let job = try scheduler.addJob(
      botID: "alpha", title: "Digest", prompt: "Summarize", cadence: 600,
      startAt: t0.addingTimeInterval(10))
    #expect(try scheduler.acquireLease(now: t0, duration: 600))
    let claim = try #require(try scheduler.claimDue(now: t0.addingTimeInterval(10), limit: 1).first)
    var restored = try JSONDecoder().decode(
      SchedulerState.self, from: JSONEncoder().encode(scheduler))
    restored.reclaimExpiredClaims(now: t0.addingTimeInterval(400))
    #expect(restored.delivery(claim.deliveryKey)?.state == .unconfirmed)
    #expect(restored.unresolvedDeliveries().count == 1)
    #expect(try restored.claimDue(now: t0.addingTimeInterval(400), limit: 10).isEmpty)
    #expect(restored.job(job)?.nextRunAt == t0.addingTimeInterval(610))
    try restored.acknowledgeUnconfirmed(
      claim.deliveryKey, resend: false, at: t0.addingTimeInterval(401))
    #expect(restored.unresolvedDeliveries().isEmpty)
    #expect(try restored.claimDue(now: t0.addingTimeInterval(401), limit: 10).isEmpty)
  }

  @Test func onlyTheLeaseHolderMayClaimAndAnExpiredLeaseIsReclaimable() throws {
    var first = state(owner: "service-a")
    _ = try first.addJob(
      botID: "alpha", title: "Digest", prompt: "Summarize", cadence: 600,
      startAt: t0.addingTimeInterval(10))
    #expect(try first.acquireLease(now: t0, duration: 60))
    var other = SchedulerState(state: first)
    other.ownerID = "service-c"
    #expect(try !other.acquireLease(now: t0.addingTimeInterval(1), duration: 60))
    let claim = try #require(try first.claimDue(now: t0.addingTimeInterval(10), limit: 1).first)
    var second = SchedulerState(state: first)
    second.ownerID = "service-b"
    #expect(try second.acquireLease(now: t0.addingTimeInterval(61), duration: 60))
    #expect(second.delivery(claim.deliveryKey)?.state == .unconfirmed)
    #expect(throws: SchedulerError.leaseLost) {
      try first.markDelivered(claim.deliveryKey, at: t0.addingTimeInterval(62))
    }
    #expect(throws: SchedulerError.leaseLost) {
      _ = try first.claimDue(now: t0.addingTimeInterval(62), limit: 1)
    }
    try second.acknowledgeUnconfirmed(
      claim.deliveryKey, resend: true, at: t0.addingTimeInterval(63))
    let retry = try #require(try second.claimDue(now: t0.addingTimeInterval(63), limit: 1).first)
    #expect(retry.deliveryKey == claim.deliveryKey)
    #expect(retry.attempt == 2)
  }

  @Test func pausedJobsAndInvalidCadenceAreRejected() throws {
    var scheduler = state()
    #expect(throws: SchedulerError.invalidCadence) {
      _ = try scheduler.addJob(
        botID: "alpha", title: "Too often", prompt: "x", cadence: 0, startAt: t0)
    }
    let job = try scheduler.addJob(
      botID: "alpha", title: "Digest", prompt: "Summarize", cadence: 600, startAt: t0)
    scheduler.setPaused(job, true)
    #expect(try scheduler.acquireLease(now: t0, duration: 3600))
    #expect(try scheduler.claimDue(now: t0.addingTimeInterval(600), limit: 10).isEmpty)
    scheduler.setPaused(job, false)
    #expect(
      try scheduler.claimDue(now: t0.addingTimeInterval(600), limit: 10).map(\.jobID) == [job])
  }
}
