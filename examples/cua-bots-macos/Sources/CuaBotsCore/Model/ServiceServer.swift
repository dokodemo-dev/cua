// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public enum ServiceServerError: Error, Equatable {
  case socketFailed, bindFailed, listenFailed, notReady, badRequest
}

/// Minimal HTTP/1.1 listener bound to 127.0.0.1 only. It exists so the router
/// can be exercised over a real socket; TLS termination and token issuance stay
/// outside this type.
public final class ServiceServer: @unchecked Sendable {
  private let api: ServiceAPI
  private let requestedPort: UInt16
  private let acceptQueue = DispatchQueue(label: "cua-bots-service.accept", qos: .userInitiated)
  // Serving must not share the accept queue: `accept` blocks, and a serial queue
  // would never run the per-connection work.
  private let workQueue = DispatchQueue(
    label: "cua-bots-service.work", qos: .userInitiated, attributes: .concurrent)
  private var descriptor: Int32 = -1
  private var running = false
  public private(set) var port: UInt16 = 0

  public init(api: ServiceAPI, requestedPort: UInt16 = 0) {
    self.api = api
    self.requestedPort = requestedPort
  }

  deinit { stop() }

  public func start() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ServiceServerError.socketFailed }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(bigEndian: requestedPort)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      close(fd)
      throw ServiceServerError.bindFailed
    }
    guard listen(fd, 16) == 0 else {
      close(fd)
      throw ServiceServerError.listenFailed
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      close(fd)
      throw ServiceServerError.notReady
    }
    descriptor = fd
    port = UInt16(bigEndian: actual.sin_port)
    running = true
    acceptQueue.async { [weak self] in self?.acceptLoop() }
    return port
  }

  public func stop() {
    guard running else { return }
    running = false
    if descriptor >= 0 {
      shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
      descriptor = -1
    }
  }

  private func acceptLoop() {
    while running {
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      workQueue.async { [weak self] in self?.serve(client) }
    }
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard let request = Self.readRequest(client) else { return }
    let response = api.handle(request)
    Self.write(response, to: client)
  }

  private static func readRequest(_ client: Int32) -> ServiceAPI.Request? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while buffer.count < 65536 {
      let count = recv(client, &chunk, chunk.count, 0)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<count])
      if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
        return parse(buffer, headerEnd: headerEnd, client: client)
      }
    }
    return nil
  }

  private static func parse(_ buffer: Data, headerEnd: Range<Data.Index>, client: Int32)
    -> ServiceAPI.Request?
  {
    let headerText = String(
      decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var lines = headerText.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    var body = buffer[headerEnd.upperBound...]
    let expected = Int(headers["content-length"] ?? "0") ?? 0
    while body.count < expected, body.count < 1_048_576 {
      var chunk = [UInt8](repeating: 0, count: 4096)
      let count = recv(client, &chunk, chunk.count, 0)
      guard count > 0 else { break }
      body.append(contentsOf: chunk[0..<count])
    }
    return ServiceAPI.Request(
      method: String(requestLine[0]), path: String(requestLine[1]),
      remoteAddress: remoteHost(client), authorization: headers["authorization"],
      body: Data(body.prefix(expected)))
  }

  private static func remoteHost(_ client: Int32) -> String {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getpeername(client, $0, &length)
      }
    }
    guard result == 0, address.sin_family == sa_family_t(AF_INET) else { return "unknown" }
    var raw = address.sin_addr
    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
      return "unknown"
    }
    return String(cString: text)
  }

  private static func write(_ response: ServiceAPI.Response, to client: Int32) {
    let reason: String
    switch response.status {
    case 200: reason = "OK"
    case 201: reason = "Created"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    case 413: reason = "Payload Too Large"
    case 429: reason = "Too Many Requests"
    default: reason = "Internal Server Error"
    }
    var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(response.body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var payload = Data(head.utf8)
    payload.append(response.body)
    payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let count = send(client, base.advanced(by: sent), raw.count - sent, 0)
        guard count > 0 else { return }
        sent += count
      }
    }
  }
}
