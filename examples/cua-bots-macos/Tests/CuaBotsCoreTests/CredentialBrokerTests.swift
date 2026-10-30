// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

struct CredentialBrokerTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func server() throws -> (ServiceServer, UInt16, String) {
    var registry = ExecutionRegistry()
    try registry.addTarget(ExecutionTarget(id: "local", name: "This Mac", kind: .local))
    try registry.addBinding(
      SpaceBinding(
        spaceID: "local:shared", targetID: "local", mode: .shared, managedByApp: false,
        trustGroup: "team-a"))
    try registry.assign(
      botID: "alpha", spaceID: "local:shared", workingDirectory: "/bots/alpha",
      trustGroup: "team-a")
    var tokens = TokenStore()
    let admin = try tokens.issue(
      botID: "admin", trustGroup: "team-a", spaceID: nil, capabilities: [.manageRegistry],
      now: now, lifetime: 3600)
    var api = ServiceAPI(
      registry: registry, tokens: tokens,
      collaboration: CollaborationService(
        authorization: AuthorizationPolicy(registry: registry), registry: registry))
    api.now = { [now] in now }
    let server = ServiceServer(api: api)
    _ = try server.start()
    return (server, server.port, admin)
  }

  @Test func provisioningNamesTheFileAndLocksItDown() {
    let plan = ServiceAccessProvisioning.plan(
      botID: "alpha", cwd: "/home/cua/bots/alpha", apiURL: "http://host.docker.internal:9123",
      credential: IssuedCredential(value: "issued-value"))
    #expect(plan.directory == "/home/cua/bots/alpha/.cua-bots")
    #expect(plan.filePath == "/home/cua/bots/alpha/.cua-bots/credential")
    #expect(plan.access.apiURL == "http://host.docker.internal:9123")
    #expect(plan.access.tokenFilePath == plan.filePath)
    #expect(plan.access.botID == "alpha")
    #expect(
      plan.commands == [
        "mkdir -p '/home/cua/bots/alpha/.cua-bots'",
        "chmod 700 '/home/cua/bots/alpha/.cua-bots'",
        "chmod 600 '/home/cua/bots/alpha/.cua-bots/credential'",
      ])
    #expect(!plan.commands.joined().contains("issued-value"))
  }

  @Test func theBrokerMintsAWorkingCredentialOverHTTP() async throws {
    let (server, port, admin) = try server()
    defer { server.stop() }
    let broker = try HTTPCredentialBroker(
      baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")), adminValue: admin)
    let credential = try await broker.mint(for: "alpha")
    #expect(!credential.value.isEmpty)
    let expiry = try #require(credential.expiresAt)
    // The broker derives the deadline from the wall clock, not the test clock.
    #expect(expiry > Date())
    let client = CuaBotsTestClient(port: port)
    #expect(
      client.get("/v1/bots/alpha/messages", authorization: "Bearer \(credential.value)")
        .hasPrefix("HTTP/1.1 200"))
    #expect(
      client.get("/v1/bots/alpha/messages", authorization: "Bearer \(admin)")
        .hasPrefix("HTTP/1.1 403"))
  }

  @Test func theBrokerOnlyTalksToLoopback() throws {
    #expect(throws: CredentialBrokerError.notLoopback) {
      _ = try HTTPCredentialBroker(
        baseURL: try #require(URL(string: "http://198.51.100.7:9123")), adminValue: "admin-value")
    }
    #expect(throws: CredentialBrokerError.malformed) {
      _ = try HTTPCredentialBroker(
        baseURL: try #require(URL(string: "http://127.0.0.1:9123")), adminValue: "  ")
    }
  }
}

/// Minimal HTTP client for the tests above; the server closes after one response.
struct CuaBotsTestClient {
  let port: UInt16

  func get(_ path: String, authorization: String?) -> String {
    var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if let authorization { request += "Authorization: \(authorization)\r\n" }
    request += "\r\n"
    return exchange(request)
  }

  private func exchange(_ request: String) -> String {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return "" }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(bigEndian: port)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return "" }
    let payload = Data(request.utf8)
    payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      _ = send(descriptor, base, raw.count, 0)
    }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(descriptor, &chunk, chunk.count, 0)
      guard count > 0 else { break }
      response.append(contentsOf: chunk[0..<count])
    }
    return String(decoding: response, as: UTF8.self)
  }
}
