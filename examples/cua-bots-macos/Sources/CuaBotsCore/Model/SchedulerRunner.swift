// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// Receives one claimed delivery. Implementations hand the prompt to a Bot; the
/// runner owns the state transitions, so an executor cannot mark anything
/// delivered on its own.
public protocol ScheduledWorkExecutor: Sendable {
  func execute(_ claim: DeliveryClaim) async throws
}

public enum ScheduledDeliveryRunnerError: Error, Equatable {
  case timedOut
}

/// Claims due slots, runs them, and records exactly what happened. A failure or
/// a timeout marks the slot `failed`; nothing is retried automatically, and the
/// same slot is never handed out twice.
public struct ScheduledDeliveryRunner: Sendable {
  public struct Outcome: Equatable, Sendable {
    public var claim: DeliveryClaim
    public var error: String?
    public var delivered: Bool { error == nil }
  }

  public var state: SchedulerState
  public var executor: ScheduledWorkExecutor
  public var timeout: TimeInterval
  public var now: @Sendable () -> Date

  public init(
    state: SchedulerState, executor: ScheduledWorkExecutor, timeout: TimeInterval = 1800,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.state = state
    self.executor = executor
    self.timeout = timeout
    self.now = now
  }

  /// Renew the lease, reclaim stale claims, then run what is due.
  @discardableResult
  public mutating func runDue(limit: Int = 4, leaseDuration: TimeInterval = 60) async -> [Outcome] {
    let started = now()
    state.reclaimExpiredClaims(now: started)
    _ = try? state.acquireLease(now: started, duration: leaseDuration)
    guard let claims = try? state.claimDue(now: started, limit: limit) else { return [] }
    var outcomes: [Outcome] = []
    for claim in claims {
      do {
        try await Self.run(executor, claim, timeout: timeout)
        try state.markDelivered(claim.deliveryKey, at: now())
        outcomes.append(Outcome(claim: claim, error: nil))
      } catch {
        try? state.markFailed(claim.deliveryKey, at: now())
        outcomes.append(Outcome(claim: claim, error: Self.describe(error)))
      }
    }
    return outcomes
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? ScheduledDeliveryRunnerError { return "\(error)" }
    return error.localizedDescription
  }

  /// Races the executor against a timer. Cancelling the losing child is best
  /// effort: an executor that ignores cancellation keeps running in the
  /// background, but the slot is already recorded as failed, so it cannot be
  /// claimed again by this runner.
  public static func run(
    _ executor: ScheduledWorkExecutor, _ claim: DeliveryClaim, timeout: TimeInterval
  ) async throws {
    guard timeout.isFinite, timeout > 0 else { throw ScheduledDeliveryRunnerError.timedOut }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await executor.execute(claim) }
      group.addTask {
        try await Task.sleep(for: .milliseconds(Int((timeout * 1000).rounded())))
        throw ScheduledDeliveryRunnerError.timedOut
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
}
