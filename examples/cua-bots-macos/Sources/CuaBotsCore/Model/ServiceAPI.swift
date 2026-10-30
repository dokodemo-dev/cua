// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// Bearer tokens are stored as hashes, expire, and map to one Bot's principal.
/// The transport must supply the remote address; a Bot never asserts either.
public struct TokenStore: Sendable {
  public struct Record: Codable, Equatable, Sendable {
    public let botID: String
    public let trustGroup: String
    public let spaceID: String?
    public let capabilities: Set<Capability>
    public let expiresAt: Date
  }
  struct Entry: Codable, Equatable, Sendable {
    var record: Record
    var revokedAt: Date?
  }

  /// Token hashes only; the bearer strings are never written down.
  public struct Snapshot: Codable, Equatable, Sendable {
    var entries: [String: Entry]
    public init() { entries = [:] }
    init(entries: [String: Entry]) { self.entries = entries }
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  public init(snapshot: Snapshot) { entries = snapshot.entries }

  public var snapshot: Snapshot { Snapshot(entries: entries) }

  @discardableResult
  public mutating func issue(
    botID: String, trustGroup: String, spaceID: String?, capabilities: Set<Capability>, now: Date,
    lifetime: TimeInterval
  ) throws -> String {
    guard lifetime.isFinite, lifetime > 0 else { throw ServiceAPIError.invalidRequest }
    let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
    let token = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    entries[Self.digest(token)] = Entry(
      record: Record(
        botID: botID, trustGroup: trustGroup, spaceID: spaceID, capabilities: capabilities,
        expiresAt: now.addingTimeInterval(lifetime)), revokedAt: nil)
    return token
  }

  public mutating func revoke(_ token: String, now: Date) {
    guard var entry = entries[Self.digest(token)] else { return }
    entry.revokedAt = now
    entries[Self.digest(token)] = entry
  }

  /// Revoke every token issued to one Bot, e.g. before handing out a new one.
  public mutating func revokeAll(botID: String, now: Date) {
    for (key, var entry) in entries where entry.record.botID == botID && entry.revokedAt == nil {
      entry.revokedAt = now
      entries[key] = entry
    }
  }

  public func authenticate(_ token: String, now: Date) -> BotPrincipal? {
    guard let entry = entries[Self.digest(token)], entry.revokedAt == nil,
      now < entry.record.expiresAt
    else { return nil }
    return BotPrincipal(
      botID: entry.record.botID, trustGroup: entry.record.trustGroup,
      capabilities: entry.record.capabilities, spaceID: entry.record.spaceID,
      groupIDs: [entry.record.trustGroup])
  }

  private static func digest(_ token: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Data(token.utf8) {
      hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

public enum ServiceAPIError: Error, Equatable {
  case invalidRequest, notFound, unauthorized, forbidden, conflict, tooLarge
}

/// Transport-free request router. A listener only supplies the remote address
/// and the authorization header, so the same policy is testable without I/O.
public struct ServiceAPI: Sendable {
  public struct Request: Equatable, Sendable {
    public var method: String
    public var path: String
    public var remoteAddress: String
    public var authorization: String?
    public var body: Data
    public init(
      method: String, path: String, remoteAddress: String, authorization: String?, body: Data
    ) {
      self.method = method
      self.path = path
      self.remoteAddress = remoteAddress
      self.authorization = authorization
      self.body = body
    }
  }

  public struct Response: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
      self.status = status
      self.body = body
    }
  }

  /// Per-token request budget. Held by reference because the router itself is a
  /// value; the lock makes it safe for concurrent connections.
  public final class RateLimiter: @unchecked Sendable {
    private let limit: Int
    private let window: TimeInterval
    private var windows: [String: (start: Date, count: Int)] = [:]
    private let lock = NSLock()

    public init(limit: Int = 60, window: TimeInterval = 60) {
      self.limit = max(1, limit)
      self.window = window
    }

    public func allow(_ key: String, now: Date) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if var entry = windows[key], now < entry.start.addingTimeInterval(window) {
        guard entry.count < limit else { return false }
        entry.count += 1
        windows[key] = entry
        return true
      }
      windows[key] = (start: now, count: 1)
      return true
    }
  }

  /// Token state is shared through a box because issuing a credential mutates it
  /// while the router value stays immutable.
  public final class TokenBox: @unchecked Sendable {
    public var store: TokenStore
    public init(_ store: TokenStore = TokenStore()) { self.store = store }
  }

  /// A reference box so the router stays immutable while the collaboration
  /// state accumulates. The listener serializes access to it.
  public final class CollaborationBox: @unchecked Sendable {
    public var service: CollaborationService
    public init(_ service: CollaborationService) { self.service = service }
  }

  public var registry: ExecutionRegistry
  public let tokenBox: TokenBox
  public var tokens: TokenStore {
    get { tokenBox.store }
    set { tokenBox.store = newValue }
  }
  public let collaboration: CollaborationBox
  public var now: @Sendable () -> Date
  /// When set, every mutation is written here before the response is returned.
  public var store: ServiceStateStore?
  /// Requests larger than this are refused before routing.
  public var bodyLimit: Int = 64 * 1024
  public var limiter: RateLimiter
  /// Called with a status and a path for refused requests; never with a token.
  public var onDenied: (@Sendable (Int, String) -> Void)?

  public init(
    registry: ExecutionRegistry, tokens: TokenStore, collaboration: CollaborationBox,
    now: @escaping @Sendable () -> Date = { Date() }, limiter: RateLimiter = RateLimiter()
  ) {
    self.registry = registry
    self.tokenBox = TokenBox(tokens)
    self.collaboration = collaboration
    self.now = now
    self.limiter = limiter
  }

  public init(
    registry: ExecutionRegistry, tokens: TokenStore, collaboration: CollaborationService,
    now: @escaping @Sendable () -> Date = { Date() }, limiter: RateLimiter = RateLimiter()
  ) {
    self.init(
      registry: registry, tokens: tokens, collaboration: CollaborationBox(collaboration), now: now,
      limiter: limiter)
  }

  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  public func handle(_ request: Request) -> Response {
    let response = respond(request)
    if response.status < 400, request.method != "GET" { persist() }
    return response
  }

  private func respond(_ request: Request) -> Response {
    let timestamp = now()
    guard request.body.count <= bodyLimit else {
      return deny(413, "request body too large", request)
    }
    if let token = Self.bearer(request), !limiter.allow(token, now: timestamp) {
      return deny(429, "too many requests", request)
    }
    let response = route(request, at: timestamp)
    if response.status >= 400 { onDenied?(response.status, request.path) }
    return response
  }

  private func deny(_ status: Int, _ message: String, _ request: Request) -> Response {
    onDenied?(status, request.path)
    return Self.error(status: status, message)
  }

  /// A Bot never gets registry management, even when a token is minted for it.
  public static let botCapabilities: Set<Capability> = [
    .spacesRead, .screenControl, .artifactsRead, .artifactsWrite, .delegate,
  ]

  private static func bearer(_ request: Request) -> String? {
    guard let header = request.authorization, header.hasPrefix("Bearer ") else { return nil }
    return String(header.dropFirst("Bearer ".count))
  }

  /// Restore a service from disk. A missing file yields an empty service.
  public static func restore(
    store: ServiceStateStore, now: @escaping @Sendable () -> Date = { Date() }
  ) throws -> ServiceAPI {
    guard let state = try store.load() else {
      let api = ServiceAPI(
        registry: ExecutionRegistry(), tokens: TokenStore(),
        collaboration: CollaborationBox(
          CollaborationService(
            authorization: AuthorizationPolicy(registry: ExecutionRegistry()),
            registry: ExecutionRegistry())), now: now)
      var restored = api
      restored.store = store
      return restored
    }
    return api(for: state, store: store, now: now)
  }

  public static func api(
    for state: ServiceState, store: ServiceStateStore? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> ServiceAPI {
    let policy = AuthorizationPolicy(registry: state.registry)
    var api = ServiceAPI(
      registry: state.registry, tokens: TokenStore(snapshot: state.tokens),
      collaboration: CollaborationBox(
        CollaborationService(
          snapshot: state.collaboration, authorization: policy, registry: state.registry)),
      now: now)
    api.store = store
    return api
  }

  public func snapshot() -> ServiceState {
    ServiceState(
      registry: registry, tokens: tokens.snapshot, collaboration: collaboration.service.snapshot)
  }

  public func persist() {
    guard let store else { return }
    try? store.save(snapshot())
  }

  private func route(_ request: Request, at timestamp: Date) -> Response {
    guard Self.isLoopback(request.remoteAddress) else {
      return Self.error(.forbidden, "management API is local only")
    }
    let parts = request.path.split(separator: "/").map(String.init)
    if parts == ["v1", "health"] { return Self.json(status: 200, ["status": "ok"]) }
    if parts.count == 5, parts[0] == "v1", parts[1] == "manage", parts[2] == "bots",
      parts[4] == "token", request.method == "POST"
    {
      return issueToken(for: parts[3], request: request, now: timestamp)
    }
    guard parts.count >= 4, parts[0] == "v1", parts[1] == "bots" else {
      return Self.error(.notFound, "unknown path")
    }
    let botID = parts[2]
    guard let token = Self.bearer(request) else {
      return Self.error(.unauthorized, "missing token")
    }
    guard let principal = tokens.authenticate(token, now: timestamp) else {
      return Self.error(.unauthorized, "invalid token")
    }
    guard principal.botID == botID else {
      return Self.error(.forbidden, "token is for another bot")
    }
    do {
      switch (request.method, parts.dropFirst(3).joined(separator: "/")) {
      case ("GET", "messages"):
        return try listMessages(principal, now: timestamp)
      case ("POST", "messages"):
        return try postMessage(principal, request, now: timestamp)
      case ("POST", "delegate"):
        return try delegate(principal, request, now: timestamp)
      case ("POST", "artifacts"):
        return try registerArtifact(principal, request, now: timestamp)
      default:
        return Self.error(.notFound, "unknown path")
      }
    } catch let error as AuthorizationError {
      if case .artifactTooLarge = error { return Self.error(status: 413, "\(error)") }
      return Self.error(.forbidden, "\(error)")
    } catch let error as CollaborationError {
      return Self.error(status: Self.status(for: error), "\(error)")
    } catch {
      return Self.error(.invalidRequest, "malformed request")
    }
  }

  /// Loopback plus an admin principal. Used by the host app to hand a fresh
  /// credential to one Bot; the response carries the value exactly once.
  private func issueToken(for botID: String, request: Request, now: Date) -> Response {
    guard let token = Self.bearer(request) else {
      return Self.error(.unauthorized, "missing token")
    }
    guard let admin = tokens.authenticate(token, now: now),
      admin.capabilities.contains(.manageRegistry),
      !registry.bindings.values.contains(where: { $0.botIDs.contains(admin.botID) })
    else {
      return Self.error(.forbidden, "admin capability required")
    }
    guard
      let binding = registry.bindings.values.first(where: { $0.botIDs.contains(botID) })
    else { return Self.error(.notFound, "unknown bot") }
    do {
      let issued = try tokenBox.store.issue(
        botID: botID, trustGroup: binding.trustGroup, spaceID: binding.spaceID,
        capabilities: Self.botCapabilities, now: now, lifetime: 3600)
      return Self.json(status: 201, ["expiresIn": "3600", "value": issued])
    } catch {
      return Self.error(.invalidRequest, "cannot issue a token")
    }
  }

  private func listMessages(_ principal: BotPrincipal, now: Date) throws -> Response {
    try authorization().check(principal, .readSpace(spaceID: principal.spaceID ?? ""), now: now)
    let messages = collaboration.service.deliverableMessages(for: principal.botID, now: now)
    let payload = messages.map {
      [
        "id": $0.id.uuidString, "sender": $0.senderBotID, "spaceID": $0.spaceID,
        "body": $0.body, "kind": $0.kind.rawValue,
      ]
    }
    return Self.json(status: 200, ["messages": payload])
  }

  private func postMessage(_ principal: BotPrincipal, _ request: Request, now: Date) throws
    -> Response
  {
    let body = try Self.decode(MessageBody.self, request.body)
    let message = try collaboration.service.post(
      from: principal, spaceID: body.spaceID, body: body.body, to: body.to,
      idempotencyKey: body.idempotencyKey, now: now)
    return Self.json(status: 201, ["id": message.id.uuidString])
  }

  private func delegate(_ principal: BotPrincipal, _ request: Request, now: Date) throws
    -> Response
  {
    let body = try Self.decode(DelegateBody.self, request.body)
    guard body.deadlineSeconds > 0, body.deadlineSeconds <= 1800 else {
      throw ServiceAPIError.invalidRequest
    }
    let before = collaboration.service.tasks.count
    let task = try collaboration.service.delegate(
      from: principal, to: body.to, spaceID: body.spaceID, prompt: body.prompt,
      parentID: body.parentID.flatMap(UUID.init(uuidString:)), idempotencyKey: body.idempotencyKey,
      now: now, deadline: now.addingTimeInterval(body.deadlineSeconds))
    let status = collaboration.service.tasks.count > before ? 201 : 200
    return Self.json(
      status: status,
      [
        "id": task.id.uuidString, "depth": String(task.depth),
        "state": task.state.rawValue,
      ])
  }

  private func registerArtifact(_ principal: BotPrincipal, _ request: Request, now: Date) throws
    -> Response
  {
    let body = try Self.decode(ArtifactBody.self, request.body)
    guard body.byteCount >= 0 else { throw ServiceAPIError.invalidRequest }
    let artifact = try collaboration.service.registerArtifact(
      from: principal, spaceID: body.spaceID, name: body.name, byteCount: body.byteCount,
      sha256: body.sha256, now: now)
    return Self.json(status: 201, ["id": artifact.id.uuidString])
  }

  private func authorization() -> AuthorizationPolicy {
    AuthorizationPolicy(registry: registry)
  }

  private struct MessageBody: Decodable {
    var spaceID: String
    var body: String
    var to: String?
    var idempotencyKey: String
  }
  private struct DelegateBody: Decodable {
    var to: String
    var spaceID: String
    var prompt: String
    var idempotencyKey: String
    var deadlineSeconds: TimeInterval
    var parentID: String?
  }
  private struct ArtifactBody: Decodable {
    var spaceID: String
    var name: String
    var byteCount: Int
    var sha256: String
  }

  private static func isLoopback(_ address: String) -> Bool {
    address == "127.0.0.1" || address == "::1"
  }

  private static func status(for error: CollaborationError) -> Int {
    switch error {
    case .artifactTooLarge: return 413
    case .idempotencyConflict: return 409
    case .depthExceeded, .delegationLoop, .concurrencyLimit: return 429
    case .notAMember, .unauthorized: return 403
    case .taskExpired, .parentExpired, .taskNotRunning: return 409
    default: return 400
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try decoder.decode(type, from: data) } catch {
      throw ServiceAPIError.invalidRequest
    }
  }

  private static func json(status: Int, _ object: [String: Any]) -> Response {
    let data =
      (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      ?? Data()
    return Response(status: status, body: data)
  }

  private static func error(_ kind: ServiceAPIError, _ message: String) -> Response {
    let status: Int
    switch kind {
    case .invalidRequest: status = 400
    case .notFound: status = 404
    case .unauthorized: status = 401
    case .forbidden: status = 403
    case .conflict: status = 409
    case .tooLarge: status = 413
    }
    return error(status: status, message)
  }

  private static func error(status: Int, _ message: String) -> Response {
    json(status: status, ["error": message])
  }
}
