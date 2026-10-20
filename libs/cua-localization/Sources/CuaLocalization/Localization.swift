// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import Foundation

public enum LanguageError: Error { case invalidPreference }

public enum DisplayLanguage {
  public static let choices = ["system", "ja", "en"]
  public static func normalize(_ value: String) -> String {
    choices.contains(value) ? value : "system"
  }
  public static func resolve(_ preference: String, preferred: [String] = Locale.preferredLanguages)
    -> String
  {
    let value = normalize(preference)
    if value != "system" { return value }
    let first = preferred.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
    return first == "ja" || first.hasPrefix("ja-") ? "ja" : "en"
  }
  public static var fileURL: URL {
    let env = ProcessInfo.processInfo.environment
    let home =
      env["HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    let root =
      env["CUA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".cua")
    return root.appendingPathComponent("ui-language.json")
  }
  public static func load(from file: URL = fileURL) -> String {
    guard let data = try? Data(contentsOf: file),
      let object = try? JSONDecoder().decode([String: String].self, from: data),
      let value = object["language"]
    else { return "system" }
    return normalize(value)
  }
  public static func save(_ preference: String, to file: URL = fileURL) throws {
    guard choices.contains(preference) else { throw LanguageError.invalidPreference }
    let data = try JSONEncoder().encode(["language": preference])
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }
}

public struct Translator: Sendable {
  public let language: String
  private static let catalogs: [String: [String: String]] = {
    var result: [String: [String: String]] = [:]
    for language in ["en", "ja"] {
      if let url = TranslationResources.bundle?.url(forResource: language, withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let entries = try? JSONDecoder().decode([String: String].self, from: data)
      {
        result[language] = entries
      }
    }
    return result
  }()
  public init(preference: String, preferred: [String] = Locale.preferredLanguages) {
    language = DisplayLanguage.resolve(preference, preferred: preferred)
  }
  public func text(_ key: String, _ arguments: [String: String] = [:]) -> String {
    let template = Self.catalogs[language]?[key] ?? Self.catalogs["en"]?[key] ?? key
    // Replace only placeholders in the template, never inside inserted user values.
    let pattern = try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")
    let matches = pattern.matches(
      in: template, range: NSRange(template.startIndex..., in: template))
    var result = template
    for match in matches.reversed() {
      guard let nameRange = Range(match.range(at: 1), in: template),
        let range = Range(match.range, in: result),
        let value = arguments[String(template[nameRange])]
      else { continue }
      result.replaceSubrange(range, with: value)
    }
    return result
  }
}
