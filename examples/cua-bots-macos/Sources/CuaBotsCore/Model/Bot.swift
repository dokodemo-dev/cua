// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import Foundation

/// Where a bot's own computer runs.
public enum Placement: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A Space on this Mac (a container under Docker or gVisor).
    case local
    /// A Cua Cloud Space.
    case cloud

    public var id: String { rawValue }
    public var name: String { self == .local ? "This Mac" : "Cua Cloud" }
}

/// Access the bot has to the user's own computer. Off until the user allows
/// it from the desktop app on that computer.
public enum HostAccess: Codable, Hashable, Sendable {
    case off
    case allowed(machine: String)

    public var isAllowed: Bool { if case .allowed = self { return true }; return false }
}

/// A named, persistent agent with an avatar and its own Space.
public struct Bot: Identifiable, Codable, Hashable, Sendable {
    /// The Volume agent name: `agents/<id>/`. 1 to 63 of `[a-z0-9._-]`.
    public var id: String
    public var name: String
    public var owner: String
    public var avatar: AvatarConfig
    public var harness: Harness
    public var placement: Placement
    /// Missing in legacy identities; nil preserves the old environment defaults.
    public var runtime: BotRuntime?
    /// The bot's own Space (`local:bot-ada`), once created.
    public var spaceID: String?
    /// The current agent run in that Space.
    public var runID: String?
    public var createdAt: Date
    public var isPaused: Bool
    /// A few words under the name: "Checking inbox", "Thinking".
    public var status: String
    public var mood: BotMood
    public var hostAccess: HostAccess

    /// Who the bots work for, as they address you and in handles:
    /// `CUA_BOTS_OWNER`, else your account name.
    public static var defaultOwner: String {
        let v = ProcessInfo.processInfo.environment["CUA_BOTS_OWNER"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? NSUserName() : v
    }

    public init(name: String, owner: String = Bot.defaultOwner, avatar: AvatarConfig? = nil,
                harness: Harness = .pi, placement: Placement = .local, runtime: BotRuntime? = nil,
                createdAt: Date = Date()) {
        self.id = Bot.agentName(for: name)
        self.name = name
        self.owner = owner
        self.avatar = avatar ?? .default(for: name)
        self.harness = harness
        self.placement = placement
        self.runtime = runtime
        self.createdAt = createdAt
        self.isPaused = false
        self.status = "Getting set up"
        self.mood = .idle
        self.hostAccess = .off
    }

    /// `@owner-name`, the way the bot is addressed in shared places.
    public var handle: String {
        "@\(Bot.agentName(for: owner))-\(id)"
    }

    /// The window title of its Space: "Ada's computer".
    public var computerTitle: String {
        name.hasSuffix("s") ? "\(name)' computer" : "\(name)'s computer"
    }

    /// The Space name this bot's computer gets.
    public var spaceName: String { "bot-\(id)" }

    /// A valid Volume agent name from a display name: lower-cased, anything
    /// outside `[a-z0-9._-]` becomes `-`, trimmed, at most 63 characters.
    public static func agentName(for name: String) -> String {
        let mapped = name.lowercased().unicodeScalars.map { c -> Character in
            let ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "." || c == "_" || c == "-"
            return ok ? Character(c) : "-"
        }
        var s = String(mapped)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if s.isEmpty { s = "bot" }
        return String(s.prefix(63))
    }
}
