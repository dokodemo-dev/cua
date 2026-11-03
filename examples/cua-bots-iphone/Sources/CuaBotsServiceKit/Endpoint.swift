// SPDX-License-Identifier: FSL-1.1-MIT

import Foundation

/// Where the app talks and with which credential.
///
/// The service is reached over the VPN, so the address is usually a private
/// IP. The credential is the same value `cua-bots-open` puts in a link.
public struct ServiceEndpoint: Sendable, Equatable, Codable {
    /// The service's address inside the VPN. It is a name, not an address: the
    /// certificate is issued by the VPN CA, whose name constraints allow only
    /// `.dokodemo-dev.internal`. The hub's CoreDNS answers it.
    public static let defaultBase = "https://bots.dokodemo-dev.internal:7717"

    public var baseURL: URL
    public var credential: String

    public init(baseURL: URL, credential: String) {
        self.baseURL = baseURL
        self.credential = credential
    }

    /// The pieces of a sign-in link: where the service is and either a
    /// one-time code (the form `cua-bots-open` hands out now) or a credential
    /// (the manual form, and links from older versions).
    public struct Link: Sendable, Equatable {
        public var base: URL
        public var code: String?
        public var credential: String?
    }

    /// Reads a link without using it: `#c=<code>` needs a trip to the service to
    /// become a credential, which the caller does asynchronously.
    public static func parseLink(_ raw: String) -> Link? {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let comps = URLComponents(string: link) else { return nil }

        if comps.scheme == "cuabots-service" {
            let items = Dictionary(comps.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            guard let url = items["url"], let token = items["token"],
                  let base = baseAddress(from: url) else { return nil }
            return Link(base: base, code: nil, credential: token)
        }
        guard comps.scheme == "http" || comps.scheme == "https",
              let base = baseAddress(from: link) else { return nil }
        if let fragment = comps.fragment, fragment.hasPrefix("c=") {
            let code = String(fragment.dropFirst(2)).removingPercentEncoding ?? ""
            return code.isEmpty ? nil : Link(base: base, code: code, credential: nil)
        }
        var token = comps.queryItems?.first(where: { $0.name == "login" })?.value
        if token == nil, let fragment = comps.fragment, fragment.hasPrefix("k=") {
            token = String(fragment.dropFirst(2)).removingPercentEncoding
        }
        guard let credential = token, !credential.isEmpty else { return nil }
        return Link(base: base, code: nil, credential: credential)
    }

    /// Accepts either a one-time-code link or a link carrying a credential
    /// (`cuabots-service://?url=...&token=...`). A code link yields nil here; use
    /// `parseLink` and exchange the code.
    public static func parse(link raw: String) -> ServiceEndpoint? {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let comps = URLComponents(string: link) else { return nil }

        if comps.scheme == "cuabots-service" {
            let items = Dictionary(comps.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                   uniquingKeysWith: { first, _ in first })
            guard let url = items["url"], let token = items["token"] else { return nil }
            return make(base: url, credential: token)
        }

        guard comps.scheme == "http" || comps.scheme == "https" else { return nil }
        var token = comps.queryItems?.first(where: { $0.name == "login" })?.value
        if token == nil, let fragment = comps.fragment, fragment.hasPrefix("k=") {
            token = String(fragment.dropFirst(2)).removingPercentEncoding
        }
        guard let credential = token, !credential.isEmpty else { return nil }
        return make(base: link, credential: credential)
    }

    /// Builds an endpoint from a typed address and a credential. A missing
    /// scheme becomes `http://`, which is what the VPN addresses look like.
    public static func make(base raw: String, credential: String) -> ServiceEndpoint? {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let url = baseAddress(from: raw) else { return nil }
        return ServiceEndpoint(baseURL: url, credential: token)
    }

    /// The service address alone. The page lives under /ui and the API at the
    /// root, so a pasted `http://host:7717/ui` is still a usable address: the
    /// app can keep it and ask only for the credential.
    public static func baseAddress(from raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "http://" + base }
        guard var comps = URLComponents(string: base),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil
        else { return nil }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { return nil }
        return url
    }
}
