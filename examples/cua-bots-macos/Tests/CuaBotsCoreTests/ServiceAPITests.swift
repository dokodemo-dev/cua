// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct ServiceAPITests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func stack() throws -> (ServiceAPI, TokenStore, [String: String]) {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:other", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-b"))
    try registry.assign(
      botID: "alpha", spaceID: "local:shared", workingDirectory: "/bots/alpha", trustGroup: "team-a"
    )
    try registry.assign(
      botID: "beta", spaceID: "local:shared", workingDirectory: "/bots/beta", trustGroup: "team-a")
    try registry.assign(
      botID: "stranger", spaceID: "local:other", workingDirectory: "/bots/stranger",
      trustGroup: "team-b")
    var tokens = TokenStore()
    let alpha = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead, .delegate, .artifactsRead, .artifactsWrite, .screenControl],
      now: now, lifetime: 3600)
    let beta = try tokens.issue(
      botID: "beta", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead, .delegate, .artifactsWrite], now: now, lifetime: 3600)
    let policy = AuthorizationPolicy(registry: registry)
    var api = ServiceAPI(
      registry: registry, tokens: tokens,
      collaboration: CollaborationService(authorization: policy, registry: registry))
    api.now = { [now] in now }
    return (api, tokens, ["alpha": alpha, "beta": beta])
  }

  private func call(
    _ api: ServiceAPI, _ method: String, _ path: String, token: String?, body: String = "{}",
    remote: String = "127.0.0.1"
  ) -> ServiceAPI.Response {
    api.handle(
      ServiceAPI.Request(
        method: method, path: path, remoteAddress: remote,
        authorization: token.map { "Bearer \($0)" }, body: Data(body.utf8)))
  }

  @Test func healthIsLoopbackOnlyAndNeedsNoToken() throws {
    let (api, _, _) = try stack()
    let ok = call(api, "GET", "/v1/health", token: nil)
    #expect(ok.status == 200)
    let remote = call(api, "GET", "/v1/health", token: nil, remote: "198.51.100.7")
    #expect(remote.status == 403)
  }

  @Test func missingExpiredAndMismatchedTokensAreRejected() throws {
    let (api, tokens, keys) = try stack()
    let alpha = try #require(keys["alpha"])
    let beta = try #require(keys["beta"])
    #expect(call(api, "GET", "/v1/bots/alpha/messages", token: nil).status == 401)
    #expect(call(api, "GET", "/v1/bots/alpha/messages", token: "not-a-token").status == 401)
    #expect(call(api, "GET", "/v1/bots/alpha/messages", token: beta).status == 403)
    var expired = tokens
    expired.revoke(alpha, now: now)
    var next = api
    next.tokens = expired
    #expect(call(next, "GET", "/v1/bots/alpha/messages", token: alpha).status == 401)
  }

  @Test func delegationIsIdempotentAndRejectsOtherGroups() throws {
    let (api, _, keys) = try stack()
    let alpha = try #require(keys["alpha"])
    let body = """
      {"to":"beta","spaceID":"local:shared","prompt":"Summarize","idempotencyKey":"k1","deadlineSeconds":60}
      """
    let first = call(api, "POST", "/v1/bots/alpha/delegate", token: alpha, body: body)
    #expect(first.status == 201)
    let second = call(api, "POST", "/v1/bots/alpha/delegate", token: alpha, body: body)
    #expect(second.status == 200)
    #expect(first.body == second.body)
    let crossGroup = """
      {"to":"stranger","spaceID":"local:shared","prompt":"Leak","idempotencyKey":"k2","deadlineSeconds":60}
      """
    #expect(
      call(api, "POST", "/v1/bots/alpha/delegate", token: alpha, body: crossGroup).status == 403)
    let tooLong = """
      {"to":"beta","spaceID":"local:shared","prompt":"Slow","idempotencyKey":"k3","deadlineSeconds":7200}
      """
    #expect(call(api, "POST", "/v1/bots/alpha/delegate", token: alpha, body: tooLong).status == 400)
  }

  @Test func artifactsAreBoundedAndOwnerScoped() throws {
    let (api, _, keys) = try stack()
    let alpha = try #require(keys["alpha"])
    let digest = String(repeating: "a", count: 64)
    let ok = """
      {"spaceID":"local:shared","name":"report.md","byteCount":1024,"sha256":"\(digest)"}
      """
    #expect(call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: ok).status == 201)
    let tooLarge = """
      {"spaceID":"local:shared","name":"big.bin","byteCount":9000000,"sha256":"\(digest)"}
      """
    #expect(
      call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: tooLarge).status == 413)
    let traversal = """
      {"spaceID":"local:shared","name":"../escape","byteCount":10,"sha256":"\(digest)"}
      """
    #expect(
      call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: traversal).status == 400)
    let betaToken = try #require(keys["beta"])
    let owned = """
      {"spaceID":"local:shared","name":"mine.md","byteCount":10,"sha256":"\(digest)"}
      """
    let forged = call(
      api, "POST", "/v1/bots/alpha/artifacts", token: betaToken, body: owned)
    #expect(forged.status == 403)
  }

  @Test func messagesAreScopedToTheAuthenticatedBot() throws {
    let (api, _, keys) = try stack()
    let alpha = try #require(keys["alpha"])
    let beta = try #require(keys["beta"])
    let post = """
      {"spaceID":"local:shared","body":"Standup at 10","idempotencyKey":"n1"}
      """
    #expect(call(api, "POST", "/v1/bots/alpha/messages", token: alpha, body: post).status == 201)
    let forBeta = call(api, "GET", "/v1/bots/beta/messages", token: beta)
    #expect(forBeta.status == 200)
    #expect(String(decoding: forBeta.body, as: UTF8.self).contains("Standup"))
    let forAlpha = call(api, "GET", "/v1/bots/alpha/messages", token: alpha)
    #expect(!String(decoding: forAlpha.body, as: UTF8.self).contains("Standup"))
  }

  @Test func stateSurvivesRestartIncludingIdempotencyAndRevocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ServiceStateStore(directory: root)
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.assign(
      botID: "alpha", spaceID: "local:shared", workingDirectory: "/bots/alpha", trustGroup: "team-a"
    )
    try registry.assign(
      botID: "beta", spaceID: "local:shared", workingDirectory: "/bots/beta", trustGroup: "team-a")
    var tokens = TokenStore()
    let alpha = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: Set(Capability.allCases), now: now, lifetime: 3600)
    var api = ServiceAPI.api(
      for: ServiceState(
        registry: registry, tokens: tokens.snapshot, collaboration: .init()), store: store)
    api.now = { [now] in now }
    api.tokens = tokens

    let delegateBody = """
      {"to":"beta","spaceID":"local:shared","prompt":"Summarize","idempotencyKey":"persist-1","deadlineSeconds":60}
      """
    let noteBody = """
      {"spaceID":"local:shared","body":"Standup at 10","idempotencyKey":"persist-note"}
      """
    let artifactBody = """
      {"spaceID":"local:shared","name":"report.md","byteCount":10,"sha256":"\(String(repeating: "a", count: 64))"}
      """
    let first = call(api, "POST", "/v1/bots/alpha/delegate", token: alpha, body: delegateBody)
    #expect(first.status == 201)
    #expect(
      call(api, "POST", "/v1/bots/alpha/messages", token: alpha, body: noteBody).status == 201)
    #expect(
      call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: artifactBody).status == 201)

    // Simulate a restart: rebuild only from the file on disk.
    var restored = try ServiceAPI.restore(store: store)
    restored.now = { [now] in now }
    let repeatDelegate = call(
      restored, "POST", "/v1/bots/alpha/delegate", token: alpha, body: delegateBody)
    #expect(repeatDelegate.status == 200)
    #expect(repeatDelegate.body == first.body)
    #expect(restored.collaboration.service.tasks.count == 1)
    var betaTokens = restored.tokens
    let betaToken = try betaTokens.issue(
      botID: "beta", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead], now: now, lifetime: 3600)
    restored.tokens = betaTokens
    #expect(
      String(
        decoding: call(restored, "GET", "/v1/bots/beta/messages", token: betaToken).body,
        as: UTF8.self
      )
      .contains("Standup"))
    #expect(restored.collaboration.service.artifacts.count == 1)

    var revoked = restored.tokens
    revoked.revoke(alpha, now: now)
    var afterRevoke = restored
    afterRevoke.tokens = revoked
    afterRevoke.persist()
    let reloaded = try ServiceAPI.restore(store: store)
    #expect(call(reloaded, "GET", "/v1/bots/alpha/messages", token: alpha).status == 401)
  }

  @Test func aRejectedRequestDoesNotChangeTheStoredState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ServiceStateStore(directory: root)
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.assign(
      botID: "alpha", spaceID: "local:shared", workingDirectory: "/bots/alpha", trustGroup: "team-a"
    )
    try registry.assign(
      botID: "stranger", spaceID: "local:shared", workingDirectory: "/bots/stranger",
      trustGroup: "team-a")
    var tokens = TokenStore()
    let alpha = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: Set(Capability.allCases), now: now, lifetime: 3600)
    var api = ServiceAPI.api(
      for: ServiceState(
        registry: registry, tokens: tokens.snapshot, collaboration: .init()), store: store)
    api.now = { [now] in now }
    api.tokens = tokens
    let bad = """
      {"spaceID":"local:missing","name":"x.md","byteCount":10,"sha256":"\(String(repeating: "b", count: 64))"}
      """
    // One accepted write establishes the file; a later rejection must not touch it.
    let good = """
      {"spaceID":"local:shared","name":"kept.md","byteCount":10,"sha256":"\(String(repeating: "c", count: 64))"}
      """
    #expect(call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: good).status == 201)
    let before = try #require(try store.load())
    #expect(call(api, "POST", "/v1/bots/alpha/artifacts", token: alpha, body: bad).status == 403)
    let after = try #require(try store.load())
    #expect(after == before)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: store.stateURL.path)[
        .posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(after.collaboration.artifacts.count == 1)

  }

  @Test func rotatingATokenRevokesOnlyThatBotsOldTokens() throws {
    var tokens = TokenStore()
    let first = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead], now: now, lifetime: 3600)
    let second = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead], now: now, lifetime: 3600)
    let other = try tokens.issue(
      botID: "beta", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead], now: now, lifetime: 3600)
    tokens.revokeAll(botID: "alpha", now: now)
    let replacement = try tokens.issue(
      botID: "alpha", trustGroup: "team-a", spaceID: "local:shared",
      capabilities: [.spacesRead], now: now, lifetime: 3600)
    #expect(tokens.authenticate(first, now: now) == nil)
    #expect(tokens.authenticate(second, now: now) == nil)
    #expect(tokens.authenticate(other, now: now)?.botID == "beta")
    #expect(tokens.authenticate(replacement, now: now)?.botID == "alpha")
    let restored = TokenStore(snapshot: tokens.snapshot)
    #expect(restored.authenticate(first, now: now) == nil)
    #expect(restored.authenticate(replacement, now: now)?.botID == "alpha")
  }

  @Test func oversizedBodiesAndBurstyCallersAreRefused() throws {
    let (api, _, keys) = try stack()
    var limited = api
    limited.limiter = ServiceAPI.RateLimiter(limit: 3, window: 60)
    limited.bodyLimit = 128
    let alpha = try #require(keys["alpha"])
    let big = String(repeating: "x", count: 200)
    let body = """
      {"spaceID":"local:shared","body":"\(big)","idempotencyKey":"big"}
      """
    #expect(
      call(limited, "POST", "/v1/bots/alpha/messages", token: alpha, body: body).status == 413)
    for _ in 0..<3 {
      #expect(call(limited, "GET", "/v1/bots/alpha/messages", token: alpha).status == 200)
    }
    #expect(call(limited, "GET", "/v1/bots/alpha/messages", token: alpha).status == 429)
    // Another Bot keeps its own budget.
    let beta = try #require(keys["beta"])
    #expect(call(limited, "GET", "/v1/bots/beta/messages", token: beta).status == 200)
  }

  @Test func refusalsAreReportedWithoutTheToken() throws {
    let (api, _, keys) = try stack()
    let collector = Collector()
    var watched = api
    watched.onDenied = { status, path in collector.append("\(status) \(path)") }
    let beta = try #require(keys["beta"])
    #expect(call(watched, "GET", "/v1/bots/alpha/messages", token: beta).status == 403)
    #expect(collector.lines == ["403 /v1/bots/alpha/messages"])
    #expect(!collector.lines.joined().contains(beta))
  }
  @Test func anAdminCanMintATokenForOneBotAndNobodyElse() throws {
    let (base, _, keys) = try stack()
    var tokens = base.tokens
    let admin = try tokens.issue(
      botID: "admin", trustGroup: "team-a", spaceID: nil, capabilities: [.manageRegistry],
      now: now, lifetime: 3600)
    var api = base
    api.tokens = tokens
    let minted = call(api, "POST", "/v1/manage/bots/alpha/token", token: admin)
    #expect(minted.status == 201)
    let object = try #require(
      JSONSerialization.jsonObject(with: minted.body) as? [String: String])
    let value = try #require(object["value"])
    #expect(call(api, "GET", "/v1/bots/alpha/messages", token: value).status == 200)
    #expect(call(api, "GET", "/v1/bots/beta/messages", token: value).status == 403)

    let alpha = try #require(keys["alpha"])
    #expect(call(api, "POST", "/v1/manage/bots/alpha/token", token: alpha).status == 403)
    #expect(call(api, "POST", "/v1/manage/bots/ghost/token", token: admin).status == 404)
    #expect(call(api, "POST", "/v1/manage/bots/alpha/token", token: nil).status == 401)
  }
}

final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(line)
  }
  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
