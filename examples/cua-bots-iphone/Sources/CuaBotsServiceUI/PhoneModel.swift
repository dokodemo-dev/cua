// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)

import CuaBotsServiceKit
import Foundation
import SwiftUI

public enum ThemePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: "システム設定に合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    public var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
public final class PhoneModel: ObservableObject {
    @Published public private(set) var endpoint: ServiceEndpoint?
    @Published public private(set) var session: SessionInfo?
    @Published public private(set) var bots: [String] = []
    @Published public private(set) var archived: [String] = []
    @Published public private(set) var avatars: [String: Avatar] = [:]
    @Published public private(set) var botSpaces: [String: String] = [:]
    @Published public private(set) var spaces: [SpaceInfo] = []
    @Published public private(set) var pins: [String] = []
    @Published public private(set) var turns: [Turn] = []
    @Published public private(set) var routines: [Routine] = []
    @Published public private(set) var artifacts: [Artifact] = []
    @Published public private(set) var busy = false
    @Published public private(set) var creating = false
    @Published public var notice: String?
    @Published public var error: String?
    /// Set when a pasted link has an address but no credential, so the sign-in
    /// form can keep the address and ask only for the missing half.
    @Published public var prefilledBase: String?
    @Published public var theme: ThemePreference {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    private var client: ServiceClient?
    private var cursor = 0
    private var polling: Task<Void, Never>?

    public init() {
        theme = ThemePreference(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system
        if let stored = CredentialStore.load() {
            endpoint = stored
            client = ServiceClient(endpoint: stored)
        }
    }

    public var isSignedIn: Bool { endpoint != nil }
    public var isAdministrator: Bool { session?.role == "administrator" }

    // MARK: - Session

    public func signIn(link: String) async -> Bool {
        if let parsed = ServiceEndpoint.parse(link: link) {
            return await connect(parsed)
        }
        if let base = ServiceEndpoint.baseAddress(from: link) {
            prefilledBase = base.absoluteString
            error = "この URL には資格情報が入っていません。接続先は下に入れました。資格情報だけ入れてください。"
            return false
        }
        error = "リンクの形式が正しくありません。cua-bots-open のリンクか、接続先と資格情報を入れてください。"
        return false
    }

    public func signIn(base: String, credential: String) async -> Bool {
        guard let parsed = ServiceEndpoint.make(base: base, credential: credential) else {
            error = "接続先か資格情報が足りません。"
            return false
        }
        return await connect(parsed)
    }

    private func connect(_ parsed: ServiceEndpoint) async -> Bool {
        let candidate = ServiceClient(endpoint: parsed)
        busy = true
        defer { busy = false }
        do {
            try await candidate.health()
            let payload = try await candidate.bots()
            endpoint = parsed
            client = candidate
            CredentialStore.save(parsed)
            apply(payload)
            session = try? await candidate.sessionInfo()
            pins = (try? await candidate.pins()) ?? []
            spaces = (try? await candidate.spaces())?.spaces ?? []
            error = nil
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    public func signOut() {
        stopPolling()
        CredentialStore.clear()
        endpoint = nil
        client = nil
        session = nil
        bots = []
        archived = []
        pins = []
        turns = []
        routines = []
        artifacts = []
        spaces = []
        error = nil
        prefilledBase = nil
    }

    // MARK: - Bots

    public func refreshBots() async {
        guard let client else { return }
        do {
            let payload = try await client.bots()
            apply(payload)
            pins = (try? await client.pins()) ?? pins
            session = try? await client.sessionInfo()
            spaces = (try? await client.spaces())?.spaces ?? spaces
        } catch {
            handle(error)
        }
    }

    private func apply(_ payload: BotsPayload) {
        bots = payload.bots
        archived = payload.archived
        avatars = payload.avatars
        botSpaces = payload.spaces
        pins = pins.filter { payload.bots.contains($0) }
    }

    public func spaceLabel(for bot: String) -> String {
        guard let space = botSpaces[bot], !space.isEmpty else { return "Space 未設定" }
        if let known = spaces.first(where: { $0.id == space }) {
            return known.name.isEmpty ? known.id : known.name
        }
        if space.hasPrefix("local:bot-") { return "ローカル" }
        return space
    }

    public func isPinned(_ bot: String) -> Bool { pins.contains(bot) }

    public func setPinned(_ bot: String, pinned: Bool) async {
        guard let client else { return }
        do {
            pins = try await client.setPin(bot: bot, pinned: pinned)
        } catch {
            handle(error)
        }
    }

    // MARK: - Creating a Bot

    /// Returns the reason it failed, or nil after the list has been refreshed.
    public func createBot(
        name: String,
        color: String,
        spaceID: String,
        createSpace: Bool
    ) async -> String? {
        guard let client else { return "サインインしていません。" }
        if let problem = BotName.problem(name) { return problem }
        let bot = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let avatar = Avatar(color: color, eyes: "star", ears: "scalloped")
        creating = true
        defer { creating = false }
        do {
            try await client.createBot(
                name: bot,
                spaceID: createSpace ? "local:bot-\(bot)" : spaceID,
                createSpace: createSpace
            )
            // Best effort: the Bot exists even if its look could not be saved.
            try? await client.setAvatar(bot: bot, avatar: avatar)
            await refreshBots()
            if createSpace {
                notice = "\(bot) の Space を作成しています（1〜2分）。"
                Task { await self.waitForSpace(bot: bot) }
            } else {
                notice = "\(bot) を追加しました。"
                clearNoticeLater()
            }
            return nil
        } catch {
            return describe(error)
        }
    }

    private func waitForSpace(bot: String) async {
        guard let client else { return }
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(3))
            guard let state = try? await client.botSpace(bot: bot) else { continue }
            if state.state == "ready" {
                notice = "\(bot) の準備ができました。"
                await refreshBots()
                clearNoticeLater()
                return
            }
            if state.state == "failed" {
                notice = "\(bot) の Space の準備に失敗しました: \(state.detail ?? "")"
                clearNoticeLater()
                return
            }
        }
        notice = "\(bot) の準備がまだ続いています。あとで一覧を更新してください。"
        clearNoticeLater()
    }

    private func clearNoticeLater() {
        let shown = notice
        Task {
            try? await Task.sleep(for: .seconds(8))
            if self.notice == shown { self.notice = nil }
        }
    }

    // MARK: - Chat

    public func open(bot: String) {
        turns = []
        cursor = 0
        routines = []
        artifacts = []
        Task { await refreshRoutines(bot: bot) }
    }

    public func startPolling(bot: String) {
        stopPolling()
        turns = []
        cursor = 0
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(bot: bot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func poll(bot: String) async {
        guard let client else { return }
        do {
            let payload = try await client.turns(bot: bot, after: cursor)
            cursor = payload.next
            merge(payload.turns)
        } catch {
            if let service = error as? ServiceError, service.needsSignIn {
                handle(error)
            }
            // Transient failures keep the last screen; the next tick retries.
        }
    }

    private func merge(_ incoming: [Turn]) {
        for turn in incoming {
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index] = turn
            } else {
                turns.append(turn)
            }
        }
        turns.sort { $0.startedAt < $1.startedAt }
    }

    public func send(bot: String, prompt: String) async -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.send(bot: bot, prompt: text)
            await poll(bot: bot)
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    // MARK: - Routines

    public func refreshRoutines(bot: String) async {
        guard let client else { return }
        do {
            routines = try await client.routines(bot: bot)
        } catch {
            handle(error)
        }
    }

    public func addRoutine(
        bot: String,
        title: String,
        prompt: String,
        everySec: Int,
        delaySec: Int
    ) async -> Bool {
        guard let client else { return false }
        do {
            try await client.addRoutine(
                bot: bot, title: title, prompt: prompt, everySec: everySec, delaySec: delaySec
            )
            await refreshRoutines(bot: bot)
            return true
        } catch {
            self.error = describe(error)
            return false
        }
    }

    public func setRoutine(bot: String, job: Routine, paused: Bool) async {
        guard let client else { return }
        do {
            try await client.setRoutine(bot: bot, job: job.id, paused: paused)
            await refreshRoutines(bot: bot)
        } catch {
            handle(error)
        }
    }

    public func deleteRoutine(bot: String, job: Routine) async {
        guard let client else { return }
        do {
            try await client.deleteRoutine(bot: bot, job: job.id)
            await refreshRoutines(bot: bot)
        } catch {
            handle(error)
        }
    }

    // MARK: - Artifacts

    public func refreshArtifacts(bot: String) async {
        guard let client else { return }
        do {
            artifacts = try await client.artifacts(bot: bot)
        } catch {
            handle(error)
        }
    }

    // MARK: - Errors

    private func handle(_ error: Error) {
        if let service = error as? ServiceError, service.needsSignIn {
            signOut()
            self.error = "サインインの期限が切れました。リンクを貼り直してください。"
            return
        }
        self.error = describe(error)
    }

    private func describe(_ error: Error) -> String {
        if let service = error as? ServiceError {
            return service.message
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "サービスに接続できません。VPN と接続先を確認してください。"
        }
        return error.localizedDescription
    }
}
#endif
