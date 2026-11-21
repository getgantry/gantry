import Foundation
import CryptoKit

/// One HTTP exchange with a registry. Tests give a fake.
public protocol RegistryHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

/// `URLSession` with no cookies and no cache, for registry requests.
public struct URLSessionRegistryHTTP: RegistryHTTP {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http, data)
    }
}

/// Why a registry check gave no digest.
public enum RegistryCheckError: Error, Equatable, Sendable {
    case unauthorized
    case notFound
    case rateLimited
    case http(Int)
    case noDigest
}

/// Reads the digest of a tag from the registry HTTP API (OCI distribution
/// spec): `HEAD /v2/<repo>/manifests/<tag>`, with the token flow of the
/// `WWW-Authenticate` challenge. It reads no image data.
public struct RegistryManifestClient: Sendable {
    /// The media types of the `docker pull` client, index types first.
    public static let acceptTypes = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json"
    ]

    private let http: any RegistryHTTP

    public init(http: any RegistryHTTP = URLSessionRegistryHTTP()) {
        self.http = http
    }

    /// The manifest digest of `reference`. `credentials` go only to the token
    /// service or to a registry that asks for Basic auth.
    public func digest(for reference: ImageReference, credentials: RegistryAuth? = nil) async throws -> String {
        guard let tag = reference.tag ?? reference.digest,
              let url = URL(string: "https://\(reference.apiHost)/v2/\(reference.repository)/manifests/\(tag)") else {
            throw RegistryCheckError.notFound
        }
        let (first, firstData) = try await http.send(Self.manifestRequest(url, authorization: nil))
        if first.statusCode != 401 { return try Self.digest(from: first, body: firstData) }
        let challenge = Self.challenge(from: first)
        guard let authorization = try await authorization(for: challenge, credentials: credentials) else {
            throw RegistryCheckError.unauthorized
        }
        let (second, secondData) = try await http.send(Self.manifestRequest(url, authorization: authorization))
        return try Self.digest(from: second, body: secondData)
    }

    /// The `Authorization` value for a challenge, or nil when none fits.
    func authorization(for challenge: AuthChallenge?, credentials: RegistryAuth?) async throws -> String? {
        switch challenge {
        case .basic:
            return Self.basicValue(credentials)
        case .bearer(let realm, let service, let scope):
            guard var components = URLComponents(string: realm) else { return nil }
            var items = components.queryItems ?? []
            if let service { items.append(URLQueryItem(name: "service", value: service)) }
            if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
            components.queryItems = items.isEmpty ? nil : items
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            if let basic = Self.basicValue(credentials) { request.setValue(basic, forHTTPHeaderField: "Authorization") }
            let (response, data) = try await http.send(request)
            guard response.statusCode == 200 else { throw Self.error(for: response.statusCode) }
            guard let token = Self.token(from: data) else { throw RegistryCheckError.unauthorized }
            return "Bearer " + token
        case nil:
            return nil
        }
    }

    static func manifestRequest(_ url: URL, authorization: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(acceptTypes.joined(separator: ", "), forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        return request
    }

    /// `Docker-Content-Digest`, or the SHA-256 of a body when a registry
    /// sends no header (a HEAD has no body, so that case is an error).
    static func digest(from response: HTTPURLResponse, body: Data) throws -> String {
        guard response.statusCode == 200 else { throw error(for: response.statusCode) }
        if let value = response.value(forHTTPHeaderField: "Docker-Content-Digest"), value.hasPrefix("sha256:") {
            return value
        }
        guard !body.isEmpty else { throw RegistryCheckError.noDigest }
        return "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    static func error(for status: Int) -> RegistryCheckError {
        switch status {
        case 401, 403: .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        default: .http(status)
        }
    }

    static func basicValue(_ credentials: RegistryAuth?) -> String? {
        // An identity token is an OAuth refresh token, not a password: the
        // check then stays anonymous.
        guard let credentials, !credentials.username.isEmpty, !credentials.password.isEmpty else { return nil }
        return "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
    }

    static func token(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token = (object["token"] as? String) ?? (object["access_token"] as? String)
        return token?.isEmpty == false ? token : nil
    }

    static func challenge(from response: HTTPURLResponse) -> AuthChallenge? {
        response.value(forHTTPHeaderField: "WWW-Authenticate").flatMap(AuthChallenge.parse)
    }
}

/// A `WWW-Authenticate` challenge of a registry.
public enum AuthChallenge: Equatable, Sendable {
    case basic
    case bearer(realm: String, service: String?, scope: String?)

    /// Parses `Bearer realm="…",service="…",scope="…"` or `Basic realm="…"`.
    public static func parse(_ header: String) -> AuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let scheme = trimmed.prefix { !$0.isWhitespace }.lowercased()
        if scheme == "basic" { return .basic }
        guard scheme == "bearer" else { return nil }
        let parameters = parameters(String(trimmed.dropFirst(scheme.count)))
        guard let realm = parameters["realm"], !realm.isEmpty else { return nil }
        return .bearer(realm: realm, service: parameters["service"], scope: parameters["scope"])
    }

    /// `key="value"` pairs. A quoted value can hold commas (scopes do).
    static func parameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index] == "," || text[index].isWhitespace { index = text.index(after: index) }
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let key = text[index..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            index = text.index(after: equals)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                while index < text.endIndex, text[index] != "," {
                    value.append(text[index])
                    index = text.index(after: index)
                }
            }
            result[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
