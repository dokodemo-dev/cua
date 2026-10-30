// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// SDK harness IDs are open-ended; an unknown saved ID must survive upgrades.
public struct Harness: RawRepresentable, Codable, Hashable, Identifiable, Sendable, CaseIterable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public var id: String { rawValue }
  public static let pi = Harness(rawValue: "pi")
  public static let hermes = Harness(rawValue: "hermes")
  public static let openclaw = Harness(rawValue: "openclaw")
  public static let codex = Harness(rawValue: "openai-codex")
  public static let claudeCode = Harness(rawValue: "claude-code")
  /// Offline fallback only. The Mac app uses the SDK catalog.
  public static let allCases: [Harness] = [.pi, .hermes, .openclaw, .codex, .claudeCode]
  public var name: String {
    switch self {
    case .pi: "Pi"
    case .hermes: "Hermes"
    case .openclaw: "OpenClaw"
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    default: rawValue
    }
  }
  public var blurb: String { self == .pi ? "Skills and extensions over ACP" : "Agent harness" }
  public var instructionsFile: String {
    switch self {
    case .claudeCode: "CLAUDE.md"
    case .hermes: "SOUL.md"
    default: "AGENTS.md"
    }
  }
  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct HarnessDescriptor: Decodable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var keys: [String]?
  public var harness: Harness { Harness(rawValue: id) }
  public static func catalog(json: String) -> [HarnessDescriptor] {
    guard let entries = try? JSONDecoder().decode([HarnessDescriptor].self, from: Data(json.utf8)),
      !entries.isEmpty
    else {
      return Harness.allCases.map { HarnessDescriptor(id: $0.id, name: $0.name, keys: nil) }
    }
    var seen: Set<String> = []
    return entries.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
  }
}

/// Non-secret references only. Paths refer to the guest, never to the Mac.
public struct BotRuntime: Codable, Hashable, Sendable {
  public var model = ""
  public var provider = ""
  public var systemPrompt = ""
  public var workingDirectory = ""
  public var piAgentDirectory = ""
  public init() {}

  public func validate() throws {
    for path in [workingDirectory, piAgentDirectory] where !path.isEmpty {
      guard path.hasPrefix("/"), !path.contains("\0"),
        !path.split(separator: "/").contains("..")
      else {
        throw RuntimeError.invalidPath
      }
    }
  }
  public enum RuntimeError: LocalizedError {
    case invalidPath
    public var errorDescription: String? { "Use an absolute guest path without '..' or NUL." }
  }
}
