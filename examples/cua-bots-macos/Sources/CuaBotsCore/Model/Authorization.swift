// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

public enum Capability: String, Codable, CaseIterable, Sendable {
  case spacesRead, screenControl, artifactsRead, artifactsWrite, delegate, manageRegistry
}

/// Issued by the service from authenticated transport and stored per Bot. A Bot
/// never supplies its own principal; the API layer derives it from the request.
public struct BotPrincipal: Codable, Equatable, Sendable {
  public var botID: String
  public var trustGroup: String
  public var capabilities: Set<Capability>
  /// The Space the Bot runs in; nil while it has none.
  public var spaceID: String?
  public var groupIDs: Set<String>

  public init(
    botID: String, trustGroup: String, capabilities: Set<Capability>, spaceID: String?,
    groupIDs: Set<String>
  ) {
    self.botID = botID
    self.trustGroup = trustGroup
    self.capabilities = capabilities
    self.spaceID = spaceID
    self.groupIDs = groupIDs
  }
}

public enum AuthorizationError: Error, Equatable {
  case missingCapability, notAMember, crossBotAccess, artifactTooLarge
  case crossTrustGroup, selfDelegation, delegationDepthExceeded, deadlineTooLong
  case screenLeaseRequired, managementNotLocal
}

/// Capability check in front of the SDK. Membership and leases come from the
/// registry, so a VPN address or a Space ID alone never authorizes an action.
public struct AuthorizationPolicy: Sendable {
  public static let maximumArtifactBytes = 8 * 1024 * 1024
  public static let maximumDelegationDepth = 3
  public static let maximumDeadline: TimeInterval = 1800
  private let registry: ExecutionRegistry

  public init(registry: ExecutionRegistry) { self.registry = registry }

  public enum Action: Equatable, Sendable {
    case readSpace(spaceID: String)
    case controlScreen(spaceID: String, leaseID: UUID?)
    case readArtifact(spaceID: String, ownerBotID: String)
    case writeArtifact(spaceID: String, ownerBotID: String, byteCount: Int)
    case delegate(toBotID: String, groupID: String, depth: Int, deadline: Date)
    case manageRegistry(remoteAddress: String)
  }

  public func check(
    _ principal: BotPrincipal, _ action: Action, now: Date = Date()
  ) throws {
    switch action {
    case .readSpace(let spaceID):
      try require(.spacesRead, principal)
      try requireMembership(principal, spaceID)
    case .controlScreen(let spaceID, let leaseID):
      try require(.screenControl, principal)
      try requireMembership(principal, spaceID)
      guard let leaseID,
        try registry.screenAllowed(
          botID: principal.botID, spaceID: spaceID, leaseID: leaseID, now: now)
      else { throw AuthorizationError.screenLeaseRequired }
    case .readArtifact(let spaceID, let ownerBotID):
      try require(.artifactsRead, principal)
      try requireMembership(principal, spaceID)
      try requireSameOwnerOrShared(principal, ownerBotID, spaceID)
    case .writeArtifact(let spaceID, let ownerBotID, let byteCount):
      try require(.artifactsWrite, principal)
      try requireMembership(principal, spaceID)
      guard ownerBotID == principal.botID else { throw AuthorizationError.crossBotAccess }
      guard byteCount >= 0, byteCount <= Self.maximumArtifactBytes else {
        throw AuthorizationError.artifactTooLarge
      }
    case .delegate(let toBotID, let groupID, let depth, let deadline):
      try require(.delegate, principal)
      guard toBotID != principal.botID else { throw AuthorizationError.selfDelegation }
      guard principal.groupIDs.contains(groupID), groupID == principal.trustGroup else {
        throw AuthorizationError.crossTrustGroup
      }
      guard depth >= 1, depth <= Self.maximumDelegationDepth else {
        throw AuthorizationError.delegationDepthExceeded
      }
      guard deadline.timeIntervalSince(now) <= Self.maximumDeadline else {
        throw AuthorizationError.deadlineTooLong
      }
    case .manageRegistry(let remoteAddress):
      try require(.manageRegistry, principal)
      guard remoteAddress == "127.0.0.1" || remoteAddress == "::1" else {
        throw AuthorizationError.managementNotLocal
      }
    }
  }

  private func require(_ capability: Capability, _ principal: BotPrincipal) throws {
    guard principal.capabilities.contains(capability) else {
      throw AuthorizationError.missingCapability
    }
  }

  private func requireMembership(_ principal: BotPrincipal, _ spaceID: String) throws {
    guard principal.spaceID == spaceID, let binding = registry.bindings[spaceID],
      binding.botIDs.contains(principal.botID), binding.trustGroup == principal.trustGroup
    else { throw AuthorizationError.notAMember }
  }

  /// A Bot always owns what it wrote. Reading another Bot's artifact requires
  /// both membership and a matching trust group, never a path guess.
  private func requireSameOwnerOrShared(
    _ principal: BotPrincipal, _ ownerBotID: String, _ spaceID: String
  ) throws {
    if ownerBotID == principal.botID { return }
    guard let binding = registry.bindings[spaceID], binding.botIDs.contains(ownerBotID),
      binding.trustGroup == principal.trustGroup
    else { throw AuthorizationError.crossBotAccess }
  }
}
