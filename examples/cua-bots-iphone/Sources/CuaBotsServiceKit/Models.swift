// SPDX-License-Identifier: FSL-1.1-MIT

import Foundation

// The shapes mirror internal/api/*.go. Keep them in step when an endpoint
// changes; unknown fields are ignored so a newer service does not break an
// older app.

public struct Avatar: Codable, Sendable, Equatable {
    public var color: String
    public var eyes: String
    public var ears: String

    public init(color: String = "sky", eyes: String = "star", ears: String = "scalloped") {
        self.color = color
        self.eyes = eyes
        self.ears = ears
    }
}

public struct BotsPayload: Decodable, Sendable {
    public var bots: [String]
    public var archived: [String]
    public var avatars: [String: Avatar]
    public var spaces: [String: String]

    public init(bots: [String] = [], archived: [String] = [],
                avatars: [String: Avatar] = [:], spaces: [String: String] = [:]) {
        self.bots = bots
        self.archived = archived
        self.avatars = avatars
        self.spaces = spaces
    }
}

public enum TurnStatus: String, Decodable, Sendable {
    case running
    case done
    case failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnStatus(rawValue: raw) ?? .done
    }
}

public struct Turn: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var prompt: String
    public var output: String
    public var status: TurnStatus
    public var error: String?
    public var startedAt: Double
    public var endedAt: Double?
}

public struct ChatPayload: Decodable, Sendable {
    public var turns: [Turn]
    public var next: Int
}

public struct Routine: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var prompt: String
    public var everySec: Double
    public var nextRunAt: Double
    public var paused: Bool
}

public struct Artifact: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var ownerBotID: String
    public var spaceID: String
    public var name: String
    public var byteCount: Int64
    public var sha256: String
    public var createdAt: Double
}

public struct SpaceState: Decodable, Sendable, Equatable {
    public var spaceID: String
    public var state: String
    public var detail: String?
}

/// The service's Bot name rule (the Volume rule): 1-63 of a-z, 0-9, dot,
/// underscore or hyphen. The browser applies the same rule before sending.
public enum BotName {
    public static let pattern = #"^[a-z0-9._-]{1,63}$"#

    public static func problem(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "名前を入れてください。" }
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            return "使えるのは半角小文字の英数字と . _ - だけです（63文字まで）。"
        }
        return nil
    }
}

public extension Avatar {
    /// Mirrors the browser's default: the name picks the colour.
    static func defaultColor(for name: String) -> String {
        let order = ["violet", "orange", "sky", "cloud", "slate", "graphite"]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return order[abs(sum) % order.count]
    }
}

public struct SessionInfo: Decodable, Sendable, Equatable {
    public var role: String
    public var botID: String
    public var capabilities: [String]
    public var expiresAt: Double?
    public var spaceID: String?
}

public struct SpacesPayload: Decodable, Sendable {
    public var spaces: [SpaceInfo]
    public var note: String?
}

public struct SpaceInfo: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var kind: String?
    public var provider: String?
}

// MARK: - Formatting shared by the views

public enum Format {
    public static func interval(_ seconds: Double) -> String {
        let value = Int(seconds)
        if value == 0 { return "-" }
        if value % 86_400 == 0 { return "\(value / 86_400)日" }
        if value % 3_600 == 0 { return "\(value / 3_600)時間" }
        if value % 60 == 0 { return "\(value / 60)分" }
        return "\(value)秒"
    }

    public static func bytes(_ count: Int64) -> String {
        if count < 1_024 { return "\(count) B" }
        if count < 1_048_576 { return String(format: "%.1f KB", Double(count) / 1_024) }
        return String(format: "%.1f MB", Double(count) / 1_048_576)
    }

    public static func dateTime(_ unix: Double) -> String {
        guard unix > 0 else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: unix))
    }

    public static func relative(_ unix: Double) -> String {
        guard unix > 0 else { return "-" }
        let diff = unix - Date().timeIntervalSince1970
        let minutes = Int((abs(diff) / 60).rounded())
        if minutes < 1 { return "まもなく" }
        if minutes < 60 { return diff > 0 ? "\(minutes)分後" : "\(minutes)分前" }
        let hours = minutes / 60
        if hours < 24 { return diff > 0 ? "\(hours)時間後" : "\(hours)時間前" }
        return dateTime(unix)
    }
}

// MARK: - Turn output

public enum TurnOutput {
    private static let noise = ["turn bot=", "[install]", "[notice]", "[turn "]

    public static func clean(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !noise.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// pi streams its reasoning as "[thinking] ..." lines; the answer follows
    /// the last marker. The split is positional because long thoughts wrap
    /// without the prefix.
    public static func split(_ text: String) -> (thinking: String, answer: String) {
        let lines = clean(text).components(separatedBy: "\n")
        guard let last = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[thinking]") })
        else { return ("", lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        let thinking = lines.prefix(through: last)
            .map { $0.replacingOccurrences(of: #"^\s*\[thinking\]\s?"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = lines.dropFirst(last + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking, answer)
    }
}
