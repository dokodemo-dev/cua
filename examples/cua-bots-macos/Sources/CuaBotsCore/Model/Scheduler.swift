// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

public enum SchedulerError: Error, Equatable {
  case invalidCadence, invalidDuration, unknownJob, unknownDelivery, invalidTransition
  case leaseLost, leaseBusy
}

public enum DeliveryState: String, Codable, Sendable {
  case claimed, pending, delivered, failed, unconfirmed
}

public struct DeliveryRecord: Codable, Equatable, Sendable {
  public let key: String
  public let jobID: UUID
  public let scheduledAt: Date
  public var state: DeliveryState
  public var attempts: Int
  public var claimedAt: Date
  public var updatedAt: Date
}

public struct ScheduledJob: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let botID: String
  public let title: String
  public let prompt: String
  public let cadence: TimeInterval
  public var nextRunAt: Date
  public var isPaused: Bool
}

public struct SchedulerLease: Codable, Equatable, Sendable {
  public let owner: String
  public let expiresAt: Date
  public let generation: Int
}

public struct DeliveryClaim: Equatable, Sendable {
  public let jobID: UUID
  public let botID: String
  public let title: String
  public let prompt: String
  public let scheduledAt: Date
  public let deliveryKey: String
  public let attempt: Int
}

/// The schedule lives outside the UI: the GUI only edits jobs through the
/// service. One lease holder claims a slot, so a second service instance or a
/// restarted app can never send the same slot twice.
public struct SchedulerState: Codable, Equatable, Sendable {
  public static let defaultClaimTimeout: TimeInterval = 120
  /// Long enough to cover the real run; the daemon can shorten it in tests.
  public var claimTimeout: TimeInterval = SchedulerState.defaultClaimTimeout
  public var ownerID: String
  public private(set) var jobs: [UUID: ScheduledJob] = [:]
  public private(set) var deliveries: [String: DeliveryRecord] = [:]
  public private(set) var lease: SchedulerLease?

  public init(ownerID: String) { self.ownerID = ownerID }
  public init(state: SchedulerState) { self = state }

  public func job(_ id: UUID) -> ScheduledJob? { jobs[id] }
  public func job(named title: String) -> ScheduledJob? {
    jobs.values.first { $0.title == title }
  }
  public func delivery(_ key: String) -> DeliveryRecord? { deliveries[key] }

  @discardableResult
  public mutating func addJob(
    botID: String, title: String, prompt: String, cadence: TimeInterval, startAt: Date
  ) throws -> UUID {
    guard cadence.isFinite, cadence >= 1 else { throw SchedulerError.invalidCadence }
    let job = ScheduledJob(
      id: UUID(), botID: botID, title: title, prompt: prompt, cadence: cadence,
      nextRunAt: startAt, isPaused: false)
    jobs[job.id] = job
    return job.id
  }

  public mutating func setPaused(_ id: UUID, _ paused: Bool) {
    jobs[id]?.isPaused = paused
  }

  /// Renewing as the current owner keeps in-flight claims; taking over from a
  /// dead owner turns them into `unconfirmed` so nobody resends blindly.
  @discardableResult
  public mutating func acquireLease(now: Date, duration: TimeInterval) throws -> Bool {
    guard duration.isFinite, duration > 0 else { throw SchedulerError.invalidDuration }
    if let lease, lease.owner != ownerID, lease.expiresAt > now { return false }
    let takeover = lease?.owner != ownerID
    let generation = takeover ? (lease?.generation ?? 0) + 1 : (lease?.generation ?? 1)
    lease = SchedulerLease(
      owner: ownerID, expiresAt: now.addingTimeInterval(duration), generation: generation)
    if takeover {
      for (key, var record) in deliveries where record.state == .claimed {
        record.state = .unconfirmed
        record.updatedAt = now
        deliveries[key] = record
      }
    }
    return true
  }

  public var hasLease: Bool { lease?.owner == ownerID }

  public mutating func claimDue(now: Date, limit: Int) throws -> [DeliveryClaim] {
    guard let lease, lease.owner == ownerID else { throw SchedulerError.leaseLost }
    guard now < lease.expiresAt else { throw SchedulerError.leaseLost }
    var claims: [DeliveryClaim] = []
    let due = jobs.values.filter { !$0.isPaused && $0.nextRunAt <= now }
      .sorted { $0.nextRunAt < $1.nextRunAt }
    for var job in due {
      guard claims.count < limit else { break }
      let key = Self.deliveryKey(jobID: job.id, scheduledAt: job.nextRunAt)
      var record =
        deliveries[key]
        ?? DeliveryRecord(
          key: key, jobID: job.id, scheduledAt: job.nextRunAt, state: .claimed, attempts: 0,
          claimedAt: now, updatedAt: now)
      // A slot that already ran (or was deliberately acknowledged) is skipped,
      // but the job must still move on instead of retrying it forever.
      guard record.state == .claimed && record.attempts == 0 || record.state == .pending else {
        job.nextRunAt = job.nextRunAt.addingTimeInterval(job.cadence)
        jobs[job.id] = job
        continue
      }
      record.attempts += 1
      record.state = .claimed
      record.claimedAt = now
      record.updatedAt = now
      deliveries[key] = record
      job.nextRunAt = job.nextRunAt.addingTimeInterval(job.cadence)
      jobs[job.id] = job
      claims.append(
        DeliveryClaim(
          jobID: job.id, botID: job.botID, title: job.title, prompt: job.prompt,
          scheduledAt: record.scheduledAt, deliveryKey: key, attempt: record.attempts))
    }
    // A slot a human explicitly asked to resend is claimable now, even though
    // its job has already moved on to the next scheduled time.
    for (key, var record) in deliveries where record.state == .pending {
      guard claims.count < limit, !claims.contains(where: { $0.deliveryKey == key }),
        let job = jobs[record.jobID]
      else { continue }
      record.attempts += 1
      record.state = .claimed
      record.claimedAt = now
      record.updatedAt = now
      deliveries[key] = record
      claims.append(
        DeliveryClaim(
          jobID: job.id, botID: job.botID, title: job.title, prompt: job.prompt,
          scheduledAt: record.scheduledAt, deliveryKey: key, attempt: record.attempts))
    }
    return claims
  }

  public mutating func markDelivered(_ key: String, at now: Date) throws {
    guard hasLease, let lease, now < lease.expiresAt else { throw SchedulerError.leaseLost }
    guard var record = deliveries[key] else { throw SchedulerError.unknownDelivery }
    guard record.state == .claimed else { throw SchedulerError.invalidTransition }
    record.state = .delivered
    record.updatedAt = now
    deliveries[key] = record
  }

  public mutating func markFailed(_ key: String, at now: Date) throws {
    guard hasLease, let lease, now < lease.expiresAt else { throw SchedulerError.leaseLost }
    guard var record = deliveries[key] else { throw SchedulerError.unknownDelivery }
    guard record.state == .claimed else { throw SchedulerError.invalidTransition }
    record.state = .failed
    record.updatedAt = now
    deliveries[key] = record
  }

  /// Called after a restart or when the lease is taken over. A claim whose
  /// outcome is unknown becomes `unconfirmed`, never `pending`.
  public mutating func reclaimExpiredClaims(now: Date) {
    for (key, var record) in deliveries where record.state == .claimed {
      guard now >= record.claimedAt.addingTimeInterval(claimTimeout) else { continue }
      record.state = .unconfirmed
      record.updatedAt = now
      deliveries[key] = record
    }
  }

  public func failedDeliveries() -> [DeliveryRecord] {
    deliveries.values.filter { $0.state == .failed }.sorted { $0.scheduledAt < $1.scheduledAt }
  }

  public func unresolvedDeliveries() -> [DeliveryRecord] {
    deliveries.values.filter { $0.state == .claimed || $0.state == .unconfirmed }
      .sorted { $0.scheduledAt < $1.scheduledAt }
  }

  /// Explicit human decision. `resend: true` requeues the same slot exactly once.
  public mutating func acknowledgeUnconfirmed(
    _ key: String, resend: Bool, at now: Date
  ) throws {
    guard var record = deliveries[key] else { throw SchedulerError.unknownDelivery }
    guard record.state == .unconfirmed || record.state == .claimed || record.state == .failed
    else {
      throw SchedulerError.invalidTransition
    }
    record.state = resend ? .pending : .failed
    record.updatedAt = now
    deliveries[key] = record
  }

  public static func deliveryKey(jobID: UUID, scheduledAt: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return "\(jobID.uuidString)@\(formatter.string(from: scheduledAt))"
  }
}
