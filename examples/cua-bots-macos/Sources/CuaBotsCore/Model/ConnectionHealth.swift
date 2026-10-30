// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

public enum ConnectionPolicyError: Error, Equatable {
  case probeAlreadyRunning, backoff, authenticationRequired, exhausted, invalidTime
}

/// No network or credentials. Probe adapters must also set a real I/O timeout
/// and cancel the request when this state expires or the service shuts down.
public struct ConnectionHealth: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case unknown, probing, online, stale, offline, unauthorized, exhausted
  }
  public enum Result: String, Codable, Sendable { case reachable, unreachable, refused }
  private struct Probe: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
  }
  private var probe: Probe?
  private var result: Result?
  private var checkedAt: Date?
  private var failures = 0
  private var retryAt: Date?
  public init() {}
  public static let freshness: TimeInterval = 30
  public static let timeout: TimeInterval = 5
  public static let maximumAttempts = 5

  public func status(at now: Date) -> Status {
    guard now.timeIntervalSince1970.isFinite else { return .stale }
    if let probe {
      return now >= probe.startedAt && now < probe.startedAt.addingTimeInterval(Self.timeout)
        ? .probing : .stale
    }
    if result == .refused { return .unauthorized }
    if failures >= Self.maximumAttempts { return .exhausted }
    guard let result, let checkedAt else { return .unknown }
    if result == .unreachable { return .offline }
    return now >= checkedAt && now < checkedAt.addingTimeInterval(Self.freshness) ? .online : .stale
  }

  public mutating func beginProbe(now: Date) throws -> UUID {
    guard now.timeIntervalSince1970.isFinite else { throw ConnectionPolicyError.invalidTime }
    expireProbe(now: now)
    guard probe == nil else { throw ConnectionPolicyError.probeAlreadyRunning }
    guard result != .refused else { throw ConnectionPolicyError.authenticationRequired }
    guard failures < Self.maximumAttempts else { throw ConnectionPolicyError.exhausted }
    guard retryAt.map({ now >= $0 }) ?? true else { throw ConnectionPolicyError.backoff }
    let id = UUID()
    probe = Probe(id: id, startedAt: now)
    return id
  }

  public mutating func completeProbe(_ id: UUID, result: Result, now: Date) {
    guard let current = probe, current.id == id, now.timeIntervalSince1970.isFinite,
      now >= current.startedAt
    else { return }
    guard now < current.startedAt.addingTimeInterval(Self.timeout) else {
      expireProbe(now: now)
      return
    }
    probe = nil
    record(result, now: now)
  }

  public mutating func expireProbe(now: Date) {
    guard now.timeIntervalSince1970.isFinite, let current = probe,
      now >= current.startedAt.addingTimeInterval(Self.timeout)
    else { return }
    probe = nil
    record(.unreachable, now: now)
  }

  public mutating func cancelProbe(_ id: UUID) {
    guard probe?.id == id else { return }
    probe = nil
  }

  public mutating func reset() { self = ConnectionHealth() }

  private mutating func record(_ result: Result, now: Date) {
    self.result = result
    checkedAt = now
    if result == .reachable {
      failures = 0
      retryAt = nil
    } else {
      failures += 1
      retryAt = now.addingTimeInterval(min(60, pow(2, Double(failures - 1))))
    }
  }
}
