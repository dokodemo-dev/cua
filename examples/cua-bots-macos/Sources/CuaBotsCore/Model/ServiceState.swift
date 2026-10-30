// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Everything the service must remember across restarts. Token values are
/// hashed in `TokenStore`, so this file never contains a usable bearer token.
public struct ServiceState: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public var version: Int
  public var registry: ExecutionRegistry
  public var tokens: TokenStore.Snapshot
  public var collaboration: CollaborationService.Snapshot

  public init(
    registry: ExecutionRegistry, tokens: TokenStore.Snapshot,
    collaboration: CollaborationService.Snapshot
  ) {
    self.version = Self.currentVersion
    self.registry = registry
    self.tokens = tokens
    self.collaboration = collaboration
  }
}

public enum ServiceStateError: Error, Equatable {
  case unsupportedVersion(Int)
  case lockFailed
}

/// Single-file state store. Writes go to a temporary file and are moved into
/// place while an exclusive lock is held, so a crash leaves either the previous
/// or the new state, never a truncated file.
public final class ServiceStateStore: @unchecked Sendable {
  public let directory: URL
  public var stateURL: URL { directory.appendingPathComponent("service-state.json") }
  public var lockURL: URL { directory.appendingPathComponent("service-state.lock") }
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(directory: URL) {
    self.directory = directory
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    decoder.dateDecodingStrategy = .iso8601
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func load() throws -> ServiceState? {
    guard let data = try? Data(contentsOf: stateURL) else { return nil }
    let state = try decoder.decode(ServiceState.self, from: data)
    guard state.version == ServiceState.currentVersion else {
      throw ServiceStateError.unsupportedVersion(state.version)
    }
    return state
  }

  public func save(_ state: ServiceState) throws {
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw ServiceStateError.lockFailed }
    defer {
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
    guard flock(descriptor, LOCK_EX) == 0 else { throw ServiceStateError.lockFailed }
    let data = try encoder.encode(state)
    let temporary = directory.appendingPathComponent("service-state.json.tmp")
    try data.write(to: temporary, options: [.atomic])
    _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: temporary)
    // The file holds messages and artifact names; keep it to the owner.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }
}
