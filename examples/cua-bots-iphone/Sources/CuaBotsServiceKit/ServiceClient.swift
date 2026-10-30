// SPDX-License-Identifier: FSL-1.1-MIT

import Foundation

public struct ServiceError: LocalizedError, Sendable, Equatable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }

    /// The page shows the sign-in gate again on this status.
    public var needsSignIn: Bool { status == 401 }
}

/// The service's HTTP API, as the phone uses it.
public struct ServiceClient: Sendable {
    public let endpoint: ServiceEndpoint
    private let session: URLSession

    public init(endpoint: ServiceEndpoint, session: URLSession = ServiceClient.defaultSession()) {
        self.endpoint = endpoint
        self.session = session
    }

    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    // MARK: - Reads

    public func health() async throws {
        _ = try await perform(path: "/v1/health")
    }

    public func bots(includeArchived: Bool = true) async throws -> BotsPayload {
        let query = includeArchived ? [URLQueryItem(name: "archived", value: "1")] : []
        let data = try await perform(path: "/v1/bots", query: query)
        return try decode(BotsPayload.self, from: data)
    }

    public func sessionInfo() async throws -> SessionInfo {
        try decode(SessionInfo.self, from: try await perform(path: "/v1/session"))
    }

    public func turns(bot: String, after cursor: Int) async throws -> ChatPayload {
        let data = try await perform(
            path: "/v1/bots/\(bot)/chat",
            query: [URLQueryItem(name: "after", value: String(cursor))]
        )
        return try decode(ChatPayload.self, from: data)
    }

    public func routines(bot: String) async throws -> [Routine] {
        struct Payload: Decodable { let routines: [Routine] }
        return try decode(Payload.self, from: try await perform(path: "/v1/bots/\(bot)/routines")).routines
    }

    public func artifacts(bot: String) async throws -> [Artifact] {
        struct Payload: Decodable { let artifacts: [Artifact] }
        return try decode(Payload.self, from: try await perform(path: "/v1/bots/\(bot)/artifacts")).artifacts
    }

    public func pins() async throws -> [String] {
        struct Payload: Decodable { let bots: [String] }
        return try decode(Payload.self, from: try await perform(path: "/v1/pins")).bots
    }

    public func spaces() async throws -> SpacesPayload {
        try decode(SpacesPayload.self, from: try await perform(path: "/v1/spaces"))
    }

    // MARK: - Writes

    public func send(bot: String, prompt: String) async throws -> Turn {
        struct Body: Encodable { let prompt: String }
        struct Payload: Decodable { let turn: Turn }
        let body = try JSONEncoder().encode(Body(prompt: prompt))
        let data = try await perform(path: "/v1/bots/\(bot)/chat", method: "POST", body: body)
        return try decode(Payload.self, from: data).turn
    }

    public func addRoutine(
        bot: String,
        title: String,
        prompt: String,
        everySec: Int,
        delaySec: Int
    ) async throws {
        struct Body: Encodable {
            let title: String
            let prompt: String
            let everySec: Int
            let delaySec: Int
        }
        let body = try JSONEncoder().encode(
            Body(title: title, prompt: prompt, everySec: everySec, delaySec: delaySec)
        )
        _ = try await perform(path: "/v1/bots/\(bot)/routines", method: "POST", body: body)
    }

    public func setRoutine(bot: String, job: String, paused: Bool) async throws {
        let action = paused ? "pause" : "resume"
        _ = try await perform(
            path: "/v1/bots/\(bot)/routines/\(job)/\(action)",
            method: "POST"
        )
    }

    public func deleteRoutine(bot: String, job: String) async throws {
        _ = try await perform(path: "/v1/bots/\(bot)/routines/\(job)", method: "DELETE")
    }

    /// Creates a Bot. The response also carries the Bot's first credential;
    /// the phone does not keep it (the admin credential stays in use).
    public func createBot(name: String, spaceID: String, createSpace: Bool) async throws {
        struct Body: Encodable {
            let botID: String
            let spaceID: String
            let createSpace: Bool
        }
        struct Payload: Decodable { let botID: String }
        let body = try JSONEncoder().encode(
            Body(botID: name, spaceID: spaceID, createSpace: createSpace)
        )
        _ = try decode(
            Payload.self,
            from: try await perform(path: "/v1/manage/bots", method: "POST", body: body)
        )
    }

    public func setAvatar(bot: String, avatar: Avatar) async throws {
        let body = try JSONEncoder().encode(avatar)
        _ = try await perform(path: "/v1/manage/bots/\(bot)/avatar", method: "POST", body: body)
    }

    public func botSpace(bot: String) async throws -> SpaceState {
        try decode(SpaceState.self, from: try await perform(path: "/v1/bots/\(bot)/space"))
    }

    public func setPin(bot: String, pinned: Bool) async throws -> [String] {
        struct Payload: Decodable { let bots: [String] }
        let data = try await perform(path: "/v1/pins/\(bot)", method: pinned ? "PUT" : "DELETE")
        return try decode(Payload.self, from: data).bots
    }

    // MARK: - Plumbing

    private func perform(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        guard var comps = URLComponents(
            url: endpoint.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ServiceError(status: 0, message: "接続先の URL が正しくありません。")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else {
            throw ServiceError(status: 0, message: "接続先の URL が正しくありません。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(status: 0, message: "応答を読めませんでした。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError(status: http.statusCode, message: Self.message(from: data, status: http.statusCode))
        }
        return data
    }

    private static func message(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data), !payload.error.isEmpty {
            return "\(payload.error)（\(status)）"
        }
        if status == 401 { return "サインインし直してください（401）" }
        if status == 403 { return "この操作は許可されていません（403）" }
        if status == 429 { return "混み合っています。少し待ってください（429）" }
        return "サービスが \(status) を返しました。"
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServiceError(status: 0, message: "応答の形式が想定と違います。")
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String
    }
}
