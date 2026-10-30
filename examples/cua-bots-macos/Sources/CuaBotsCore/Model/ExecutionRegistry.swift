// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// Metadata only. Credentials and raw Space tokens never belong in this record.
public struct ExecutionTarget: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case local, direct, legacyCloud }
  public var id: String
  public var name: String
  public var kind: Kind
  public var endpoint: URL?
  public var credentialReference: String?

  public init(
    id: String, name: String, kind: Kind, endpoint: URL? = nil,
    credentialReference: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.endpoint = endpoint
    self.credentialReference = credentialReference
  }
}

public struct ScreenLease: Codable, Equatable, Sendable {
  public let id: UUID
  public let botID: String
  public let expiresAt: Date
}

public struct SpaceBinding: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable { case exclusive, shared }
  public let spaceID: String
  public let targetID: String
  public let mode: Mode
  public let managedByApp: Bool
  /// Bots may only share a Space with the same group. Defaults to "default"
  /// so records written before the field existed stay readable.
  public let trustGroup: String
  public fileprivate(set) var workspaces: [String: String] = [:]
  public fileprivate(set) var screenLease: ScreenLease?
  public var botIDs: Set<String> { Set(workspaces.keys) }

  public init(
    spaceID: String, targetID: String, mode: Mode, managedByApp: Bool,
    trustGroup: String = "default"
  ) {
    self.spaceID = spaceID
    self.targetID = targetID
    self.mode = mode
    self.managedByApp = managedByApp
    self.trustGroup = trustGroup
  }

  enum CodingKeys: String, CodingKey {
    case spaceID, targetID, mode, managedByApp, trustGroup, workspaces, screenLease
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    spaceID = try c.decode(String.self, forKey: .spaceID)
    targetID = try c.decode(String.self, forKey: .targetID)
    mode = try c.decode(Mode.self, forKey: .mode)
    managedByApp = try c.decode(Bool.self, forKey: .managedByApp)
    trustGroup = try c.decodeIfPresent(String.self, forKey: .trustGroup) ?? "default"
    workspaces = try c.decodeIfPresent([String: String].self, forKey: .workspaces) ?? [:]
    screenLease = try c.decodeIfPresent(ScreenLease.self, forKey: .screenLease)
  }
}

public enum ExecutionRegistryError: Error, Equatable {
  case invalidIdentity, invalidWorkspace, overlappingWorkspace
  case duplicateTarget, duplicateBinding, unknownTarget, unknownSpace
  case exclusiveSpaceOccupied, botNotAssigned, botAlreadyAssigned
  case screenBusy, staleLease, invalidLeaseDuration
  case trustGroupMismatch
}

/// A Space that already exists (created outside the app, or shared by another
/// Bot). Creating a Bot there never provisions or deletes that Space.
public struct ExistingSpaceAssignment: Codable, Equatable, Sendable {
  public var spaceID: String
  public var targetID: String
  public var targetName: String
  public var trustGroup: String
  public var workingDirectory: String

  public init(
    spaceID: String, targetID: String, targetName: String, trustGroup: String,
    workingDirectory: String
  ) {
    self.spaceID = spaceID
    self.targetID = targetID
    self.targetName = targetName
    self.trustGroup = trustGroup
    self.workingDirectory = workingDirectory
  }
}

/// Pure ownership policy. The service must serialize and persist mutations, and
/// enforce the same policy before SDK calls. Lexical path separation is not a
/// filesystem sandbox: the guest adapter must separately reject symlink aliases.
public struct ExecutionRegistry: Codable, Equatable, Sendable {
  public enum DetachEffect: Equatable { case preserve, deleteOwnedSpace }
  public private(set) var targets: [String: ExecutionTarget] = [:]
  public private(set) var bindings: [String: SpaceBinding] = [:]
  public init() {}

  public mutating func addTarget(_ target: ExecutionTarget) throws {
    guard !target.id.isEmpty, !target.id.contains("\0") else {
      throw ExecutionRegistryError.invalidIdentity
    }
    guard targets[target.id] == nil else { throw ExecutionRegistryError.duplicateTarget }
    targets[target.id] = target
  }

  public mutating func addBinding(_ binding: SpaceBinding) throws {
    guard !binding.spaceID.isEmpty, !binding.spaceID.contains("\0") else {
      throw ExecutionRegistryError.invalidIdentity
    }
    guard targets[binding.targetID] != nil else { throw ExecutionRegistryError.unknownTarget }
    guard bindings[binding.spaceID] == nil else { throw ExecutionRegistryError.duplicateBinding }
    bindings[binding.spaceID] = binding
  }

  public mutating func assign(
    botID: String, spaceID: String, workingDirectory: String, trustGroup: String = "default"
  ) throws {
    guard !botID.isEmpty, Bot.agentName(for: botID) == botID else {
      throw ExecutionRegistryError.invalidIdentity
    }
    guard var binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    let path = try Self.validatedWorkspace(workingDirectory)
    if binding.mode == .shared, trustGroup != binding.trustGroup {
      throw ExecutionRegistryError.trustGroupMismatch
    }
    if bindings.values.contains(where: { $0.spaceID != spaceID && $0.botIDs.contains(botID) }) {
      throw ExecutionRegistryError.botAlreadyAssigned
    }
    if binding.mode == .exclusive && !binding.botIDs.subtracting([botID]).isEmpty {
      throw ExecutionRegistryError.exclusiveSpaceOccupied
    }
    for (other, existing) in binding.workspaces where other != botID {
      if path == existing || path.hasPrefix(existing + "/") || existing.hasPrefix(path + "/") {
        throw ExecutionRegistryError.overlappingWorkspace
      }
    }
    binding.workspaces[botID] = path
    bindings[spaceID] = binding
  }

  public mutating func detach(botID: String, spaceID: String) throws -> DetachEffect {
    guard var binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    guard binding.workspaces.removeValue(forKey: botID) != nil else {
      throw ExecutionRegistryError.botNotAssigned
    }
    if binding.screenLease?.botID == botID { binding.screenLease = nil }
    bindings[spaceID] = binding
    return binding.managedByApp && binding.mode == .exclusive && binding.botIDs.isEmpty
      ? .deleteOwnedSpace : .preserve
  }

  /// Call only after the SDK confirms deletion. External/shared records stay.
  public mutating func confirmOwnedSpaceDeleted(_ spaceID: String) throws {
    guard let binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    guard binding.managedByApp, binding.mode == .exclusive, binding.botIDs.isEmpty else {
      throw ExecutionRegistryError.exclusiveSpaceOccupied
    }
    bindings[spaceID] = nil
  }

  public mutating func acquireScreen(
    botID: String, spaceID: String, now: Date, duration: TimeInterval
  ) throws -> ScreenLease {
    guard duration.isFinite, duration > 0, duration <= 300, now.timeIntervalSince1970.isFinite
    else {
      throw ExecutionRegistryError.invalidLeaseDuration
    }
    guard var binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    guard binding.botIDs.contains(botID) else { throw ExecutionRegistryError.botNotAssigned }
    guard binding.screenLease.map({ $0.expiresAt <= now }) ?? true else {
      throw ExecutionRegistryError.screenBusy
    }
    let lease = ScreenLease(id: UUID(), botID: botID, expiresAt: now.addingTimeInterval(duration))
    binding.screenLease = lease
    bindings[spaceID] = binding
    return lease
  }

  public func screenAllowed(botID: String, spaceID: String, leaseID: UUID, now: Date) throws -> Bool
  {
    guard let binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    guard binding.botIDs.contains(botID) else { throw ExecutionRegistryError.botNotAssigned }
    guard now.timeIntervalSince1970.isFinite else { return false }
    return binding.screenLease.map { $0.id == leaseID && $0.botID == botID && now < $0.expiresAt }
      ?? false
  }

  public mutating func releaseScreen(botID: String, spaceID: String, leaseID: UUID) throws {
    guard var binding = bindings[spaceID] else { throw ExecutionRegistryError.unknownSpace }
    guard binding.botIDs.contains(botID) else { throw ExecutionRegistryError.botNotAssigned }
    guard binding.screenLease?.id == leaseID, binding.screenLease?.botID == botID else {
      throw ExecutionRegistryError.staleLease
    }
    binding.screenLease = nil
    bindings[spaceID] = binding
  }

  /// Idempotent migration of one Phase 1 identity. Never grants ownership of an
  /// existing Space; imported bindings cannot delete or suspend that computer.
  public mutating func migrate(_ bot: inout Bot) throws {
    var next = self
    let targetID = bot.executionTargetID ?? "legacy-\(bot.placement.rawValue)"
    if next.targets[targetID] == nil {
      try next.addTarget(
        ExecutionTarget(
          id: targetID, name: bot.placement.name,
          kind: bot.placement == .local ? .local : .legacyCloud))
    }
    if let spaceID = bot.spaceID {
      if next.bindings[spaceID] == nil {
        try next.addBinding(
          SpaceBinding(spaceID: spaceID, targetID: targetID, mode: .shared, managedByApp: false))
      }
      guard next.bindings[spaceID]?.targetID == targetID else {
        throw ExecutionRegistryError.unknownTarget
      }
      let cwd =
        bot.runtime?.workingDirectory.isEmpty == false
        ? bot.runtime!.workingDirectory : "/home/cua/bots/\(bot.id)"
      try next.assign(botID: bot.id, spaceID: spaceID, workingDirectory: cwd)
    }
    self = next
    bot.executionTargetID = targetID
  }

  private static func validatedWorkspace(_ path: String) throws -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("/"), path != "/", !path.contains("\0"), !path.contains("\n"),
      !path.contains("\r"), parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ExecutionRegistryError.invalidWorkspace }
    return path
  }
}
