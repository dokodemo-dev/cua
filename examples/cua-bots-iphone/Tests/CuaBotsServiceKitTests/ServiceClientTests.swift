// SPDX-License-Identifier: FSL-1.1-MIT

import XCTest
@testable import CuaBotsServiceKit

final class EndpointTests: XCTestCase {
    /// The link `cua-bots-open` hands out now carries a one-time code, not the
    /// credential; the app exchanges it.
    func testParsesTheOneTimeCodeLink() {
        let pieces = ServiceEndpoint.parseLink(
            "https://bots.dokodemo-dev.internal:7717/ui#c=abc123"
        )
        XCTAssertEqual(pieces?.base.absoluteString, "https://bots.dokodemo-dev.internal:7717")
        XCTAssertEqual(pieces?.code, "abc123")
        XCTAssertNil(pieces?.credential)
        XCTAssertNil(ServiceEndpoint.parse(link: "https://bots.dokodemo-dev.internal:7717/ui#c=abc123"))
    }

    func testParsesTheLoginLinkTheCommandProduces() {
        let endpoint = ServiceEndpoint.parse(
            link: "http://vpn-host:7717/ui?login=abc123"
        )
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://vpn-host:7717")
        XCTAssertEqual(endpoint?.credential, "abc123")
    }

    func testParsesTheAppScheme() {
        let endpoint = ServiceEndpoint.parse(
            link: "cuabots-service://?url=http%3A%2F%2Fvpn-host%3A7717&token=tok"
        )
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://vpn-host:7717")
        XCTAssertEqual(endpoint?.credential, "tok")
    }

    func testAcceptsTheFragmentCredential() {
        let endpoint = ServiceEndpoint.parse(link: "http://vpn-host:7717/ui#k=frag")
        XCTAssertEqual(endpoint?.credential, "frag")
    }

    /// The TLS switch rewrites only the scheme of a stored http address, so a
    /// saved sign-in keeps its host, port and credential.
    func testTLSSchemeUpgradeKeepsHostPortAndCredential() throws {
        let stored = try XCTUnwrap(
            ServiceEndpoint.make(base: "http://bots.dokodemo-dev.internal:7717", credential: "token")
        )
        var comps = try XCTUnwrap(URLComponents(url: stored.baseURL, resolvingAgainstBaseURL: false))
        comps.scheme = "https"
        let upgraded = ServiceEndpoint(baseURL: try XCTUnwrap(comps.url), credential: stored.credential)
        XCTAssertEqual(upgraded.baseURL.absoluteString, "https://bots.dokodemo-dev.internal:7717")
        XCTAssertEqual(upgraded.credential, stored.credential)
    }

    func testRefusesALinkWithoutACredential() {
        XCTAssertNil(ServiceEndpoint.parse(link: "http://vpn-host:7717/ui"))
        XCTAssertNil(ServiceEndpoint.parse(link: "ftp://vpn-host/ui?login=x"))
        XCTAssertNil(ServiceEndpoint.parse(link: ""))
    }

    func testAddsHTTPSchemeWhenTypingAnAddress() {
        let endpoint = ServiceEndpoint.make(base: "vpn-host:7717", credential: "tok")
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://vpn-host:7717")
    }

    func testDropsPathAndQueryFromTypedAddress() {
        let endpoint = ServiceEndpoint.make(base: "http://vpn-host:7717/ui?x=1", credential: "tok")
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://vpn-host:7717")
    }

    func testKeepsTheAddressOfALinkWithoutACredential() {
        XCTAssertNil(ServiceEndpoint.parse(link: "http://vpn-host:7717/ui"))
        XCTAssertEqual(
            ServiceEndpoint.baseAddress(from: "http://vpn-host:7717/ui")?.absoluteString,
            "http://vpn-host:7717"
        )
        XCTAssertEqual(
            ServiceEndpoint.baseAddress(from: "vpn-host:7717")?.absoluteString,
            "http://vpn-host:7717"
        )
        XCTAssertNil(ServiceEndpoint.baseAddress(from: "not a url"))
    }

    func testRefusesUserInfoInTheAddress() {
        XCTAssertNil(ServiceEndpoint.make(base: "http://user@vpn-host:7717", credential: "tok"))
    }
}

final class ServiceClientTests: XCTestCase {
    private func client(
        status: Int = 200,
        body: String,
        check: @escaping (URLRequest) -> Void = { _ in }
    ) -> (ServiceClient, () -> [URLRequest]) {
        var seen: [URLRequest] = []
        StubProtocol.responder = { request in
            seen.append(request)
            check(request)
            return (status, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = ServiceEndpoint(
            baseURL: URL(string: "http://vpn-host:7717")!,
            credential: "secret"
        )
        return (ServiceClient(endpoint: endpoint, session: session), { seen })
    }

    func testSendsTheCredentialAndDecodesBots() async throws {
        let (client, requests) = client(
            body: #"{"bots":["alpha"],"archived":[],"avatars":{"alpha":{"color":"sky","eyes":"star","ears":"scalloped"}},"spaces":{"alpha":"local:demo"}}"#
        )
        let payload = try await client.bots()
        XCTAssertEqual(payload.bots, ["alpha"])
        XCTAssertEqual(payload.spaces["alpha"], "local:demo")
        XCTAssertEqual(requests().first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(requests().first?.url?.path, "/v1/bots")
        XCTAssertEqual(requests().first?.url?.query, "archived=1")
    }

    func testAsksForTurnsAfterACursor() async throws {
        let (client, requests) = client(body: #"{"turns":[],"next":4}"#)
        let payload = try await client.turns(bot: "alpha", after: 4)
        XCTAssertEqual(payload.next, 4)
        XCTAssertEqual(requests().first?.url?.path, "/v1/bots/alpha/chat")
        XCTAssertEqual(requests().first?.url?.query, "after=4")
    }

    func testTurnsA401IntoASignInError() async {
        let (client, _) = client(status: 401, body: #"{"error":"invalid token"}"#)
        do {
            _ = try await client.bots()
            XCTFail("expected a 401")
        } catch let error as ServiceError {
            XCTAssertTrue(error.needsSignIn)
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(error.message.contains("invalid token"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPostsAPromptAsJSON() async throws {
        let (client, requests) = client(
            body: #"{"turn":{"id":"1","prompt":"hi","output":"","status":"running","startedAt":1}}"#
        )
        let turn = try await client.send(bot: "alpha", prompt: "hi")
        XCTAssertEqual(turn.id, "1")
        let request = try XCTUnwrap(requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSetsAndClearsAPin() async throws {
        let (client, requests) = client(body: #"{"bots":["alpha"]}"#)
        let bots = try await client.setPin(bot: "alpha", pinned: true)
        XCTAssertEqual(bots, ["alpha"])
        XCTAssertEqual(requests().first?.httpMethod, "PUT")
        XCTAssertEqual(requests().first?.url?.path, "/v1/pins/alpha")
    }
}

final class BotNameTests: XCTestCase {
    func testAcceptsTheVolumeRule() {
        XCTAssertNil(BotName.problem("research"))
        XCTAssertNil(BotName.problem("a.b_c-1"))
        XCTAssertNil(BotName.problem(String(repeating: "a", count: 63)))
    }

    func testRejectsUppercaseSpacesAndOverlongNames() {
        XCTAssertNotNil(BotName.problem("Research"))
        XCTAssertNotNil(BotName.problem("でるた"))
        XCTAssertNotNil(BotName.problem("has space"))
        XCTAssertNotNil(BotName.problem(""))
        XCTAssertNotNil(BotName.problem(String(repeating: "a", count: 64)))
    }

    func testDefaultColorFollowsTheName() {
        XCTAssertEqual(Avatar.defaultColor(for: "research"), Avatar.defaultColor(for: "research"))
        XCTAssertTrue(["violet", "orange", "sky", "cloud", "slate", "graphite"]
            .contains(Avatar.defaultColor(for: "research")))
    }
}

final class CreateBotTests: XCTestCase {
    private func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testCreatesABotInTheChosenSpace() async throws {
        var seen: [URLRequest] = []
        StubProtocol.responder = { request in
            seen.append(request)
            return (201, Data(#"{"botID":"gamma","spaceID":"local:new"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = ServiceClient(
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://vpn-host:7717")!, credential: "secret"),
            session: URLSession(configuration: configuration)
        )

        try await client.createBot(name: "gamma", spaceID: "local:new", createSpace: true)
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/manage/bots")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body(request).utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["botID"] as? String, "gamma")
        XCTAssertEqual(json["spaceID"] as? String, "local:new")
        XCTAssertEqual(json["createSpace"] as? Bool, true)
    }

    func testSavesTheAvatarAndReadsTheSpaceState() async throws {
        var paths: [String] = []
        StubProtocol.responder = { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/space") == true {
                return (200, Data(#"{"spaceID":"local:new","state":"pending"}"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = ServiceClient(
            endpoint: ServiceEndpoint(baseURL: URL(string: "http://vpn-host:7717")!, credential: "secret"),
            session: URLSession(configuration: configuration)
        )

        try await client.setAvatar(bot: "gamma", avatar: Avatar(color: "violet", eyes: "star", ears: "scalloped"))
        let state = try await client.botSpace(bot: "gamma")
        XCTAssertEqual(state.state, "pending")
        XCTAssertEqual(paths, ["/v1/manage/bots/gamma/avatar", "/v1/bots/gamma/space"])
    }
}

final class TurnOutputTests: XCTestCase {
    func testDropsTheRunnersOwnLines() {
        let raw = "turn bot=alpha\n[install] working\n[notice] hi\nhello\n[turn 1 ended]"
        XCTAssertEqual(TurnOutput.clean(raw), "hello")
    }

    func testSplitsThinkingFromTheAnswer() {
        let raw = "[thinking] plan\n[thinking] more\nanswer"
        let parts = TurnOutput.split(raw)
        XCTAssertEqual(parts.thinking, "plan\nmore")
        XCTAssertEqual(parts.answer, "answer")
    }

    func testKeepsAnswersThatHaveNoThinking() {
        let parts = TurnOutput.split("### title\n- item")
        XCTAssertEqual(parts.thinking, "")
        XCTAssertEqual(parts.answer, "### title\n- item")
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://vpn-host")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

