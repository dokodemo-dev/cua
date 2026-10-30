// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// One freshly issued Bot credential and when it stops working.
public struct IssuedCredential: Equatable, Sendable {
  public var value: String
  public var expiresAt: Date?

  public init(value: String, expiresAt: Date? = nil) {
    self.value = value
    self.expiresAt = expiresAt
  }
}

public enum CredentialBrokerError: Error, Equatable {
  case refused(Int)
  case malformed, notLoopback
}

/// The host side of credential delivery: ask the service for a Bot credential.
public protocol ServiceCredentialBroker: Sendable {
  func mint(for botID: String) async throws -> IssuedCredential
}

/// Talks to `POST /v1/manage/bots/<id>/token`. The admin value stays on the host;
/// only a loopback base URL is accepted so it cannot be pointed at a remote host.
public struct HTTPCredentialBroker: ServiceCredentialBroker {
  public let baseURL: URL
  private let adminValue: String
  private let session: URLSession

  public init(baseURL: URL, adminValue: String, session: URLSession = .shared) throws {
    guard let host = baseURL.host, host == "127.0.0.1" || host == "::1" else {
      throw CredentialBrokerError.notLoopback
    }
    guard !adminValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CredentialBrokerError.malformed
    }
    self.baseURL = baseURL
    self.adminValue = adminValue
    self.session = session
  }

  public func mint(for botID: String) async throws -> IssuedCredential {
    let escaped = botID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? botID
    guard let url = URL(string: "\(baseURL.absoluteString)/v1/manage/bots/\(escaped)/token")
    else { throw CredentialBrokerError.malformed }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(adminValue)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = Data("{}".utf8)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 201 else { throw CredentialBrokerError.refused(status) }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = object["value"] as? String, !value.isEmpty
    else { throw CredentialBrokerError.malformed }
    let lifetime = Double(object["expiresIn"] as? String ?? "")
    return IssuedCredential(
      value: value, expiresAt: lifetime.map { Date().addingTimeInterval($0) })
  }
}

/// Where a Bot's credential goes inside its Space, and the commands that make the
/// file readable only by that Bot's user. Kept pure so the paths and modes are
/// testable without a Space.
public struct ServiceAccessPlan: Equatable, Sendable {
  public let access: BotServiceAccess
  public let directory: String
  public let filePath: String
  public let commands: [String]
}

public enum ServiceAccessProvisioning {
  public static let directoryName = ".cua-bots"
  public static let fileName = "credential"

  public static func plan(
    botID: String, cwd: String, apiURL: String, credential: IssuedCredential
  ) -> ServiceAccessPlan {
    let directory = "\(cwd)/\(directoryName)"
    let filePath = "\(directory)/\(fileName)"
    let q = HarnessLaunch.quote
    return ServiceAccessPlan(
      access: BotServiceAccess(apiURL: apiURL, tokenFilePath: filePath, botID: botID),
      directory: directory,
      filePath: filePath,
      commands: [
        "mkdir -p \(q(directory))",
        "chmod 700 \(q(directory))",
        "chmod 600 \(q(filePath))",
      ])
  }
}
