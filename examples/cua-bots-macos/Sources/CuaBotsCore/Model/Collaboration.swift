// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

public enum CollaborationError: Error, Equatable {
  case idempotencyConflict, idempotencyKeyRequired, parentNotFound, parentExpired
  case delegationLoop, depthExceeded, concurrencyLimit, taskExpired, taskNotRunning
  case artifactTooLarge, invalidArtifactName, notAMember, unauthorized
}

public struct CollaborationMessage: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case note, delegation, result }
  public let id: UUID
  public let kind: Kind
  public let idempotencyKey: String
  public let senderBotID: String
  public let recipientBotID: String?
  public let spaceID: String
  public let body: String
  public let createdAt: Date
}

public struct DelegationTask: Codable, Equatable, Sendable, Identifiable {
  public enum State: String, Codable, Sendable { case running, succeeded, expired }
  public let id: UUID
  public let parentID: UUID?
  public let depth: Int
  public let senderBotID: String
  public let recipientBotID: String
  public let spaceID: String
  public let deadline: Date
  /// Every Bot that already handled this root task, oldest first.
  public let path: [String]
  public var state: State
  public var result: String?
}

public struct ArtifactRef: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let ownerBotID: String
  public let spaceID: String
  public let name: String
  public let byteCount: Int
  public let sha256: String
  public let createdAt: Date
}

/// Harness-independent collaboration state. The service owns one instance and
/// serializes calls; Bots reach it only through their own principal.
public struct CollaborationService: Sendable {
  public static let maximumGlobalConcurrency = 4
  public static let maximumPerBotConcurrency = 1
  struct Stored: Codable, Equatable, Sendable {
    var task: DelegationTask
    var prompt: String
    var fingerprint: String
  }

  /// What survives a restart. The policy is rebuilt from the registry instead of
  /// being stored, so a stale snapshot can never widen permissions.
  public struct Snapshot: Codable, Equatable, Sendable {
    var stored: [UUID: Stored]
    public var taskCount: Int { stored.count }
    public var messageCount: Int { messages.count }
    public var artifactCount: Int { artifacts.count }
    var byKey: [String: UUID]
    var messages: [CollaborationMessage]
    var artifacts: [ArtifactRef]
    public init() {
      stored = [:]
      byKey = [:]
      messages = []
      artifacts = []
    }
    init(
      stored: [UUID: Stored], byKey: [String: UUID], messages: [CollaborationMessage],
      artifacts: [ArtifactRef]
    ) {
      self.stored = stored
      self.byKey = byKey
      self.messages = messages
      self.artifacts = artifacts
    }
  }
  private let authorization: AuthorizationPolicy
  private let registry: ExecutionRegistry
  private var stored: [UUID: Stored] = [:]
  private var byKey: [String: UUID] = [:]
  public private(set) var messages: [CollaborationMessage] = []
  public private(set) var artifacts: [ArtifactRef] = []

  public init(authorization: AuthorizationPolicy, registry: ExecutionRegistry) {
    self.authorization = authorization
    self.registry = registry
  }

  public init(
    snapshot: Snapshot, authorization: AuthorizationPolicy, registry: ExecutionRegistry
  ) {
    self.init(authorization: authorization, registry: registry)
    stored = snapshot.stored
    byKey = snapshot.byKey
    messages = snapshot.messages
    artifacts = snapshot.artifacts
  }

  public var snapshot: Snapshot {
    Snapshot(stored: stored, byKey: byKey, messages: messages, artifacts: artifacts)
  }

  public var tasks: [DelegationTask] {
    stored.values.map(\.task).sorted { $0.id.uuidString < $1.id.uuidString }
  }
  public var runningCount: Int { stored.values.filter { $0.task.state == .running }.count }
  public func task(_ id: UUID) -> DelegationTask? { stored[id]?.task }
  public func runningCount(for botID: String) -> Int {
    stored.values.filter { $0.task.state == .running && $0.task.recipientBotID == botID }.count
  }

  @discardableResult
  public mutating func delegate(
    from principal: BotPrincipal, to recipientBotID: String, spaceID: String, prompt: String,
    parentID: UUID? = nil, idempotencyKey: String, now: Date, deadline: Date
  ) throws -> DelegationTask {
    guard !idempotencyKey.isEmpty else { throw CollaborationError.idempotencyKeyRequired }
    let fingerprint = "\(recipientBotID)\u{1}\(spaceID)\u{1}\(prompt)"
    if let existing = byKey[idempotencyKey] {
      guard let record = stored[existing], record.fingerprint == fingerprint else {
        throw CollaborationError.idempotencyConflict
      }
      return record.task
    }
    let parentPath: [String]
    var depth = 1
    var effectiveDeadline = deadline
    if let parentID {
      guard let parent = stored[parentID]?.task else { throw CollaborationError.parentNotFound }
      guard parent.state != .expired else { throw CollaborationError.parentExpired }
      guard parent.state == .running else { throw CollaborationError.taskNotRunning }
      parentPath = parent.path
      depth = parent.depth + 1
      effectiveDeadline = min(deadline, parent.deadline)
    } else {
      parentPath = [principal.botID]
    }
    guard !parentPath.contains(recipientBotID) else { throw CollaborationError.delegationLoop }
    guard depth <= AuthorizationPolicy.maximumDelegationDepth else {
      throw CollaborationError.depthExceeded
    }
    try authorization.check(
      principal,
      .delegate(
        toBotID: recipientBotID, groupID: principal.trustGroup, depth: depth,
        deadline: effectiveDeadline), now: now)
    guard now < effectiveDeadline else { throw CollaborationError.taskExpired }
    // The policy checks the caller's group; the recipient must be in the same
    // group and the same Space, otherwise a Bot could reach across boundaries.
    guard let binding = registry.bindings[spaceID], binding.trustGroup == principal.trustGroup,
      binding.botIDs.contains(principal.botID), binding.botIDs.contains(recipientBotID)
    else { throw CollaborationError.unauthorized }
    guard runningCount < Self.maximumGlobalConcurrency,
      runningCount(for: recipientBotID) < Self.maximumPerBotConcurrency
    else { throw CollaborationError.concurrencyLimit }
    let task = DelegationTask(
      id: UUID(), parentID: parentID, depth: depth, senderBotID: principal.botID,
      recipientBotID: recipientBotID, spaceID: spaceID, deadline: effectiveDeadline,
      path: parentPath + [recipientBotID], state: .running, result: nil)
    stored[task.id] = Stored(task: task, prompt: prompt, fingerprint: fingerprint)
    byKey[idempotencyKey] = task.id
    messages.append(
      CollaborationMessage(
        id: UUID(), kind: .delegation, idempotencyKey: idempotencyKey,
        senderBotID: principal.botID, recipientBotID: recipientBotID, spaceID: spaceID,
        body: prompt, createdAt: now))
    return task
  }

  public mutating func complete(taskID: UUID, result: String, now: Date) throws {
    guard var record = stored[taskID] else { throw CollaborationError.taskNotRunning }
    guard record.task.state == .running else {
      throw record.task.state == .expired
        ? CollaborationError.taskExpired : CollaborationError.taskNotRunning
    }
    guard now < record.task.deadline else {
      record.task.state = .expired
      stored[taskID] = record
      throw CollaborationError.taskExpired
    }
    record.task.state = .succeeded
    record.task.result = result
    stored[taskID] = record
    messages.append(
      CollaborationMessage(
        id: UUID(), kind: .result, idempotencyKey: "result-\(taskID.uuidString)",
        senderBotID: record.task.recipientBotID, recipientBotID: record.task.senderBotID,
        spaceID: record.task.spaceID, body: result, createdAt: now))
  }

  public mutating func expire(now: Date) {
    for (id, var record) in stored where record.task.state == .running {
      guard now >= record.task.deadline else { continue }
      record.task.state = .expired
      stored[id] = record
    }
  }

  @discardableResult
  public mutating func post(
    from principal: BotPrincipal, spaceID: String, body: String, to recipientBotID: String? = nil,
    idempotencyKey: String, now: Date
  ) throws -> CollaborationMessage {
    guard !idempotencyKey.isEmpty else { throw CollaborationError.idempotencyKeyRequired }
    guard let binding = registry.bindings[spaceID], binding.botIDs.contains(principal.botID),
      principal.spaceID == spaceID, binding.trustGroup == principal.trustGroup
    else { throw CollaborationError.notAMember }
    if let recipientBotID {
      guard binding.botIDs.contains(recipientBotID) else { throw CollaborationError.notAMember }
    }
    if let existing = messages.first(where: { $0.idempotencyKey == idempotencyKey }) {
      return existing
    }
    let message = CollaborationMessage(
      id: UUID(), kind: .note, idempotencyKey: idempotencyKey, senderBotID: principal.botID,
      recipientBotID: recipientBotID, spaceID: spaceID, body: body, createdAt: now)
    messages.append(message)
    return message
  }

  /// Undelivered means: addressed to this Bot (or to everyone in its Space),
  /// not written by it, and not already past its Space binding.
  public func deliverableMessages(for botID: String, now: Date) -> [CollaborationMessage] {
    let spaces = Set(
      registry.bindings.values.filter { $0.botIDs.contains(botID) }.map(\.spaceID))
    return messages.filter { message in
      message.senderBotID != botID && spaces.contains(message.spaceID)
        && message.createdAt <= now
        && (message.recipientBotID == nil || message.recipientBotID == botID)
    }
  }

  @discardableResult
  public mutating func registerArtifact(
    from principal: BotPrincipal, spaceID: String, name: String, byteCount: Int, sha256: String,
    now: Date
  ) throws -> ArtifactRef {
    try authorization.check(
      principal,
      .writeArtifact(spaceID: spaceID, ownerBotID: principal.botID, byteCount: byteCount),
      now: now)
    guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix("."),
      !name.contains("/"), !name.contains("\\"), !name.contains("\0")
    else { throw CollaborationError.invalidArtifactName }
    let artifact = ArtifactRef(
      id: UUID(), ownerBotID: principal.botID, spaceID: spaceID, name: name,
      byteCount: byteCount, sha256: sha256, createdAt: now)
    artifacts.append(artifact)
    return artifact
  }

  public func artifacts(for botID: String, now: Date) -> [ArtifactRef] {
    let spaces = Set(
      registry.bindings.values.filter { $0.botIDs.contains(botID) }.map(\.spaceID))
    return artifacts.filter { spaces.contains($0.spaceID) }
  }
}
