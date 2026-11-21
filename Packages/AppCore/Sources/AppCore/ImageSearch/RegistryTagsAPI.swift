import Foundation
import DockerKit

/// A repository on a registry, parsed from text such as
/// `ghcr.io/owner/image` or `nginx:latest`. A tag or a digest is dropped.
public struct RegistryRepository: Sendable, Equatable {
    /// The host the API calls go to (`registry-1.docker.io` for Docker Hub).
    public var registryHost: String
    /// The registry domain for credentials (`docker.io` for Docker Hub).
    public var domain: String
    /// The path of the repository (`library/nginx`).
    public var path: String
    /// The reference that `docker pull` takes, without a tag (`nginx`, `ghcr.io/o/i`).
    public var pullName: String

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = value.firstIndex(of: "@") { value = String(value[..<at]) }
        if let colon = value.lastIndex(of: ":"), !value[colon...].contains("/") {
            value = String(value[..<colon])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        // A host with no repository ("ghcr.io") is not a Docker Hub name.
        if !value.contains("/"), value.contains(".") { return nil }
        let domain = RegistryCredentialStore.registryDomain(forImageReference: value)
        var path = value
        if domain != "docker.io" || value.hasPrefix("docker.io/") {
            guard let slash = value.firstIndex(of: "/") else { return nil }
            path = String(value[value.index(after: slash)...])
        }
        guard !path.isEmpty else { return nil }
        if domain == "docker.io" {
            if !path.contains("/") { path = "library/\(path)" }
            registryHost = "registry-1.docker.io"
            pullName = path.hasPrefix("library/") ? String(path.dropFirst("library/".count)) : path
        } else {
            registryHost = domain
            pullName = "\(domain)/\(path)"
        }
        self.domain = domain
        self.path = path
    }

    public var isDockerHub: Bool { domain == "docker.io" }
}

/// `GET /v2/<name>/tags/list` of the registry API v2, with the bearer token
/// flow of `WWW-Authenticate`. Pages of 1000, at most 10 of them. Credentials are asked for only after a 401,
/// so a public repository never reads the credential store.
public struct RegistryTagsAPI: Sendable {
    public typealias Credentials = @Sendable (_ reference: String) async -> RegistryAuth?

    private let http: any RegistryHTTP
    private let credentials: Credentials
    private let maxPages: Int

    public init(http: any RegistryHTTP, maxPages: Int = 10, credentials: @escaping Credentials) {
        self.http = http
        self.maxPages = maxPages
        self.credentials = credentials
    }

    public func tags(_ repository: RegistryRepository) async throws -> [ImageTag] {
        var names: [String] = []
        var next: URL? = Self.firstPageURL(repository)
        var authorization: String?
        var pages = 0
        while let url = next, pages < maxPages {
            pages += 1
            var response = try await send(url, authorization: authorization)
            if response.status == 401, authorization == nil {
                authorization = try await authorize(response, repository: repository)
                if let authorization { response = try await send(url, authorization: authorization) }
            }
            guard response.status == 200 else {
                throw ImageSearchError.from(status: response.status, headers: response.headers)
            }
            names += try Self.parseTagList(response.body)
            next = Self.nextPageURL(link: response.headers["link"], base: url)
        }
        return Self.sorted(names).map { ImageTag(name: $0) }
    }

    private func send(_ url: URL, authorization: String?) async throws -> RegistryHTTPResponse {
        var headers = ["Accept": "application/json"]
        if let authorization { headers["Authorization"] = authorization }
        do {
            return try await http.send(RegistryHTTPRequest(url: url, headers: headers))
        } catch {
            throw ImageSearchError.from(error)
        }
    }

    /// The `Authorization` value after a 401, or nil when the registry gives
    /// no usable challenge.
    private func authorize(_ response: RegistryHTTPResponse, repository: RegistryRepository) async throws -> String? {
        guard let challenge = response.headers["www-authenticate"].flatMap(AuthChallenge.init) else { return nil }
        let auth = await credentials(repository.pullName)
        switch challenge.scheme {
        case "basic":
            guard let auth, !auth.username.isEmpty else { return nil }
            return Self.basic(auth)
        case "bearer":
            return try await bearerToken(challenge, repository: repository, auth: auth).map { "Bearer \($0)" }
        default:
            return nil
        }
    }

    private func bearerToken(_ challenge: AuthChallenge, repository: RegistryRepository, auth: RegistryAuth?) async throws -> String? {
        guard let realm = challenge.parameters["realm"], var components = URLComponents(string: realm),
              components.scheme == "https" || components.host == "localhost" else { return nil }
        let service = challenge.parameters["service"]
        let scope = challenge.parameters["scope"] ?? "repository:\(repository.path):pull"
        var request: RegistryHTTPRequest
        if let token = auth?.identityToken, !token.isEmpty {
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: token),
                URLQueryItem(name: "service", value: service ?? ""),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "client_id", value: "gantry")
            ]
            guard let url = components.url else { return nil }
            request = RegistryHTTPRequest(
                method: "POST", url: url,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data((form.percentEncodedQuery ?? "").utf8)
            )
        } else {
            var items = components.queryItems ?? []
            if let service { items.append(URLQueryItem(name: "service", value: service)) }
            items.append(URLQueryItem(name: "scope", value: scope))
            components.queryItems = items
            guard let url = components.url else { return nil }
            request = RegistryHTTPRequest(url: url)
            if let auth, !auth.username.isEmpty { request.headers["Authorization"] = Self.basic(auth) }
        }
        let response: RegistryHTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw ImageSearchError.from(error)
        }
        guard response.status == 200 else {
            throw ImageSearchError.from(status: response.status, headers: response.headers)
        }
        return Self.parseToken(response.body)
    }

    // MARK: - Pure helpers

    static func basic(_ auth: RegistryAuth) -> String {
        "Basic " + Data("\(auth.username):\(auth.password)".utf8).base64EncodedString()
    }

    static func firstPageURL(_ repository: RegistryRepository) -> URL? {
        var components = URLComponents()
        components.scheme = repository.registryHost.hasPrefix("localhost") ? "http" : "https"
        let hostParts = repository.registryHost.split(separator: ":", maxSplits: 1)
        components.host = String(hostParts[0])
        if hostParts.count == 2 { components.port = Int(hostParts[1]) }
        components.path = "/v2/\(repository.path)/tags/list"
        components.queryItems = [URLQueryItem(name: "n", value: "1000")]
        return components.url
    }

    static func parseTagList(_ data: Data) throws -> [String] {
        struct Page: Decodable { var tags: [String]? }
        return try JSONDecoder().decode(Page.self, from: data).tags ?? []
    }

    static func parseToken(_ data: Data) -> String? {
        struct Reply: Decodable { var token: String?; var access_token: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return [reply.token, reply.access_token].compactMap { $0 }.first { !$0.isEmpty }
    }

    static func isArtifactTag(_ name: String) -> Bool {
        name.wholeMatch(of: /sha256-[0-9a-f]{64}(\.(sig|att|sbom))?/) != nil
    }

    /// `</v2/x/tags/list?last=a&n=100>; rel="next"` resolved on the same host.
    static func nextPageURL(link: String?, base: URL) -> URL? {
        guard let link, link.contains("rel=\"next\""),
              let open = link.firstIndex(of: "<"), let close = link.firstIndex(of: ">"), open < close
        else { return nil }
        let target = String(link[link.index(after: open)..<close])
        guard let url = URL(string: target, relativeTo: base)?.absoluteURL, url.host == base.host else { return nil }
        return url
    }

    /// `latest` first, then newest-looking names first (natural order, reversed).
    /// Signature and attestation tags (`sha256-<digest>[.sig|.att|.sbom]`) are not images.
    static func sorted(_ names: [String]) -> [String] {
        let unique = Set(names).filter { !isArtifactTag($0) }
        return unique.sorted { lhs, rhs in
            if lhs == "latest" { return rhs != "latest" }
            if rhs == "latest" { return false }
            return lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedDescending
        }
    }
}

/// A parsed `WWW-Authenticate` header: `Bearer realm="…",service="…",scope="…"`.
struct AuthChallenge: Equatable {
    var scheme: String
    var parameters: [String: String]

    init?(_ header: String) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else {
            guard !trimmed.isEmpty else { return nil }
            scheme = trimmed.lowercased()
            parameters = [:]
            return
        }
        scheme = trimmed[..<space].lowercased()
        var result: [String: String] = [:]
        let rest = trimmed[trimmed.index(after: space)...]
        let pattern = /([A-Za-z_]+)="([^"]*)"/
        for match in rest.matches(of: pattern) {
            result[String(match.1).lowercased()] = String(match.2)
        }
        parameters = result
    }
}
