// SPDX-License-Identifier: FSL-1.1-MIT
import Foundation

/// Renders a launchd job for a long-lived helper. Writing and loading the job is
/// deliberately left to the operator: rendering cannot start anything by itself,
/// and no token value ever appears in the plist.
public struct ServiceLaunchd: Equatable, Sendable {
  public struct Job: Equatable, Sendable {
    public var label: String
    public var program: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var stateDirectory: String
    public var keepAlive: Bool
    public var runAtLoad: Bool
    public var throttleInterval: Int

    public init(
      label: String, program: String, arguments: [String] = [], workingDirectory: String? = nil,
      stateDirectory: String, keepAlive: Bool = true, runAtLoad: Bool = true,
      throttleInterval: Int = 10
    ) {
      self.label = label
      self.program = program
      self.arguments = arguments
      self.workingDirectory = workingDirectory
      self.stateDirectory = stateDirectory
      self.keepAlive = keepAlive
      self.runAtLoad = runAtLoad
      self.throttleInterval = throttleInterval
    }
  }

  public enum ManifestError: Error, Equatable {
    case emptyLabel, relativeProgram, invalidThrottle
  }

  /// A macOS property-list XML document. Values are escaped, so a path with an
  /// ampersand cannot break the document.
  public static func propertyList(_ job: Job) throws -> String {
    guard !job.label.isEmpty,
      job.label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
    else { throw ManifestError.emptyLabel }
    guard job.program.hasPrefix("/") else { throw ManifestError.relativeProgram }
    guard job.throttleInterval >= 0 else { throw ManifestError.invalidThrottle }
    var lines = [
      #"<?xml version="1.0" encoding="UTF-8"?>"#,
      #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
      #"<plist version="1.0">"#,
      "<dict>",
      "  <key>Label</key>",
      "  <string>\(escape(job.label))</string>",
      "  <key>ProgramArguments</key>",
      "  <array>",
      "    <string>\(escape(job.program))</string>",
    ]
    for argument in job.arguments {
      lines.append("    <string>\(escape(argument))</string>")
    }
    lines.append(contentsOf: [
      "  </array>",
      "  <key>RunAtLoad</key>",
      job.runAtLoad ? "  <true/>" : "  <false/>",
      "  <key>KeepAlive</key>",
      job.keepAlive ? "  <true/>" : "  <false/>",
      "  <key>ThrottleInterval</key>",
      "  <integer>\(job.throttleInterval)</integer>",
      "  <key>StandardOutPath</key>",
      "  <string>\(escape("\(job.stateDirectory)/launchd.out.log"))</string>",
      "  <key>StandardErrorPath</key>",
      "  <string>\(escape("\(job.stateDirectory)/launchd.err.log"))</string>",
    ])
    if let workingDirectory = job.workingDirectory {
      lines.append(contentsOf: [
        "  <key>WorkingDirectory</key>",
        "  <string>\(escape(workingDirectory))</string>",
      ])
    }
    lines.append(contentsOf: ["</dict>", "</plist>", ""])
    return lines.joined(separator: "\n")
  }

  public static func fileName(label: String) -> String { "\(label).plist" }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
