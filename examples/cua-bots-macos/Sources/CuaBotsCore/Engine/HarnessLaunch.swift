// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// Pure launch configuration, shared by the SDK adapter and offline tests.
public struct HarnessLaunch: Sendable {
  public static let promptHeader = "<!-- Managed by Cua Bots -->\n"
  public var cwd: String
  public var model: String?
  public var environment: [String: String] = [:]
  public var files: [String: Data] = [:]

  public init(bot: Bot, home: String, endpointModel: String? = nil, customEndpoint: Bool = false)
    throws
  {
    let runtime = bot.runtime ?? BotRuntime()
    try runtime.validate()
    cwd = runtime.workingDirectory.isEmpty ? home : runtime.workingDirectory
    model = runtime.model.isEmpty ? endpointModel : runtime.model
    guard bot.harness == .pi else { return }
    // A custom endpoint is generated in the SDK's run-local pi-agent dir.
    if customEndpoint && !runtime.piAgentDirectory.isEmpty {
      throw LaunchError.endpointDirectoryConflict
    }
    if !customEndpoint {
      environment["PI_CODING_AGENT_DIR"] =
        runtime.piAgentDirectory.isEmpty
        ? "\(home)/.pi-agent" : runtime.piAgentDirectory
    }
    environment["PI_OFFLINE"] = "1"
    var settings: [String: String] = [:]
    if let model { settings["defaultModel"] = model }
    if customEndpoint {
      settings["defaultProvider"] = "cua"
    } else if !runtime.provider.isEmpty {
      settings["defaultProvider"] = runtime.provider
    }
    files["\(cwd)/.pi/settings.json"] = try JSONSerialization.data(
      withJSONObject: settings, options: [.sortedKeys])
    // Empty data requests removal of our previous managed prompt only.
    files["\(cwd)/.pi/APPEND_SYSTEM.md"] =
      runtime.systemPrompt.isEmpty
      ? Data()
      : Data((Self.promptHeader + runtime.systemPrompt).utf8)
  }

  /// Preserve project resource lists, including extensions and skills.
  public static func mergeSettings(existing: Data, managed: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
      let overrides = try JSONSerialization.jsonObject(with: managed) as? [String: Any]
    else {
      throw CocoaError(.propertyListReadCorrupt)
    }
    object.removeValue(forKey: "defaultModel")
    object.removeValue(forKey: "defaultProvider")
    object.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  public static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
  public enum LaunchError: LocalizedError {
    case endpointDirectoryConflict
    public var errorDescription: String? {
      "A custom endpoint uses the SDK's run-local Pi config. Clear the Pi agent directory or the endpoint."
    }
  }
}
