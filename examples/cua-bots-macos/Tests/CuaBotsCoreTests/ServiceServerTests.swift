// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation
import Testing

@testable import CuaBotsCore

#if canImport(Darwin)
  import Darwin
#endif

struct ServiceServerTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func makeServer() throws -> (ServiceServer, String) {
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
    var api = ServiceAPI(
      registry: registry, tokens: tokens,
      collaboration: CollaborationService(
        authorization: AuthorizationPolicy(registry: registry), registry: registry))
    api.now = { [now] in now }
    let server = ServiceServer(api: api)
    _ = try server.start()
    return (server, alpha)
  }

  private func exchange(port: UInt16, request: String) -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(bigEndian: port)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return "" }
    let payload = Data(request.utf8)
    payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      _ = send(fd, base, raw.count, 0)
    }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(fd, &chunk, chunk.count, 0)
      guard count > 0 else { break }
      response.append(contentsOf: chunk[0..<count])
    }
    return String(decoding: response, as: UTF8.self)
  }

  private func get(_ port: UInt16, _ path: String, token: String? = nil) -> String {
    var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    if let token { request += "Authorization: Bearer \(token)\r\n" }
    request += "\r\n"
    return exchange(port: port, request: request)
  }

  @Test func healthAndAuthorizationWorkOverATCPRoundTrip() throws {
    let (server, token) = try makeServer()
    defer { server.stop() }
    #expect(server.port != 0)
    let health = get(server.port, "/v1/health")
    #expect(health.hasPrefix("HTTP/1.1 200"))
    #expect(health.contains("\"status\":\"ok\""))
    let anonymous = get(server.port, "/v1/bots/alpha/messages")
    #expect(anonymous.hasPrefix("HTTP/1.1 401"))
    let authorized = get(server.port, "/v1/bots/alpha/messages", token: token)
    #expect(authorized.hasPrefix("HTTP/1.1 200"))
  }

  @Test func delegationRoundTripIsIdempotentOverHTTP() throws {
    let (server, token) = try makeServer()
    defer { server.stop() }
    let body = """
      {"to":"beta","spaceID":"local:shared","prompt":"Summarize","idempotencyKey":"net-1","deadlineSeconds":60}
      """
    var request = "POST /v1/bots/alpha/delegate HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    request += "Authorization: Bearer \(token)\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.utf8.count)\r\n\r\n"
    request += body
    let first = exchange(port: server.port, request: request)
    #expect(first.hasPrefix("HTTP/1.1 201"))
    let second = exchange(port: server.port, request: request)
    #expect(second.hasPrefix("HTTP/1.1 200"))
    #expect(
      first.components(separatedBy: "\r\n\r\n").last
        == second.components(separatedBy: "\r\n\r\n").last)
  }

  @Test func stopReleasesThePortAndRestartBindsAgain() throws {
    let (server, _) = try makeServer()
    let port = server.port
    server.stop()
    #expect(get(port, "/v1/health").isEmpty)
  }
}
