// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct ConnectionPolicyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func freshnessExpiresAndOldProbeCannotOverrideLatest() throws {
    var state = ConnectionHealth()
    let first = try state.beginProbe(now: now)
    state.completeProbe(first, result: .reachable, now: now)
    #expect(state.status(at: now.addingTimeInterval(29)) == .online)
    #expect(state.status(at: now.addingTimeInterval(30)) == .stale)
    let second = try state.beginProbe(now: now.addingTimeInterval(31))
    state.completeProbe(first, result: .refused, now: now.addingTimeInterval(32))
    state.completeProbe(second, result: .reachable, now: now.addingTimeInterval(33))
    #expect(state.status(at: now.addingTimeInterval(34)) == .online)
    #expect(state.status(at: now.addingTimeInterval(-1)) == .stale)
  }

  @Test func timeoutsAreBoundedAndAuthenticationFailureDoesNotRetry() throws {
    var state = ConnectionHealth()
    let first = try state.beginProbe(now: now)
    #expect(throws: ConnectionPolicyError.probeAlreadyRunning) {
      _ = try state.beginProbe(now: now)
    }
    state.expireProbe(now: now.addingTimeInterval(5))
    #expect(state.status(at: now.addingTimeInterval(5)) == .offline)
    #expect(throws: ConnectionPolicyError.backoff) {
      _ = try state.beginProbe(now: now.addingTimeInterval(5))
    }
    let second = try state.beginProbe(now: now.addingTimeInterval(6))
    state.completeProbe(second, result: .refused, now: now.addingTimeInterval(6))
    #expect(state.status(at: now.addingTimeInterval(6)) == .unauthorized)
    #expect(throws: ConnectionPolicyError.authenticationRequired) {
      _ = try state.beginProbe(now: now.addingTimeInterval(300))
    }
    state.reset()
    _ = try state.beginProbe(now: now.addingTimeInterval(301))
  }

  @Test func exhaustionRequiresExplicitResetAndCancelledProbeDoesNotComeBack() throws {
    var state = ConnectionHealth()
    var at = now
    for attempt in 0..<5 {
      let id = try state.beginProbe(now: at)
      state.completeProbe(id, result: .unreachable, now: at)
      at = at.addingTimeInterval(pow(2, Double(attempt)))
    }
    #expect(state.status(at: at) == .exhausted)
    #expect(throws: ConnectionPolicyError.exhausted) { _ = try state.beginProbe(now: at) }
    state.reset()
    let id = try state.beginProbe(now: at)
    state.cancelProbe(id)
    state.completeProbe(id, result: .reachable, now: at)
    #expect(state.status(at: at) == .unknown)
    #expect(
      try JSONDecoder().decode(ConnectionHealth.self, from: JSONEncoder().encode(state)) == state)
  }
}
