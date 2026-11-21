import Foundation
import DockerKit

/// The Docker Hub HTTP API (`hub.docker.com/v2`): search and tags.
/// Apple hosts use it for the search, because `container` has no search.
public struct DockerHubAPI: Sendable {
    public static let host = "hub.docker.com"

    private let http: any RegistryHTTP

    public init(http: any RegistryHTTP) {
        self.http = http
    }

    public func search(_ query: String, pageSize: Int = 25) async throws -> [ImageSearchResult] {
        let body = try await get(Self.searchURL(query: query, pageSize: pageSize))
        return try Self.parseSearch(body)
    }

    public func tags(repository: String, pageSize: Int = 50) async throws -> [ImageTag] {
        let body = try await get(Self.tagsURL(repository: repository, pageSize: pageSize))
        return try Self.parseTags(body)
    }

    private func get(_ url: URL) async throws -> Data {
        let response: RegistryHTTPResponse
        do {
            response = try await http.send(RegistryHTTPRequest(url: url, headers: ["Accept": "application/json"]))
        } catch {
            throw ImageSearchError.from(error)
        }
        guard response.status == 200 else {
            throw ImageSearchError.from(status: response.status, headers: response.headers)
        }
        return response.body
    }

    // MARK: - URLs

    static func searchURL(query: String, pageSize: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v2/search/repositories/"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ]
        return components.url!
    }

    /// `nginx` is `library/nginx` in the API.
    static func tagsURL(repository: String, pageSize: Int) -> URL {
        let path = repository.contains("/") ? repository : "library/\(repository)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v2/repositories/\(path)/tags/"
        components.queryItems = [
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "ordering", value: "last_updated")
        ]
        return components.url!
    }

    // MARK: - Parsers

    private struct SearchPage: Decodable {
        struct Row: Decodable {
            var repo_name: String
            var short_description: String?
            var star_count: Int?
            var is_official: Bool?
        }
        var results: [Row]?
    }

    static func parseSearch(_ data: Data) throws -> [ImageSearchResult] {
        let page = try JSONDecoder().decode(SearchPage.self, from: data)
        return (page.results ?? []).map {
            ImageSearchResult(
                name: $0.repo_name,
                description: $0.short_description ?? "",
                starCount: $0.star_count ?? 0,
                isOfficial: $0.is_official ?? false
            )
        }
    }

    private struct TagsPage: Decodable {
        struct Row: Decodable {
            struct Image: Decodable {
                var architecture: String?
                var os: String?
                var variant: String?
                var size: Int64?
            }
            var name: String
            var full_size: Int64?
            var last_updated: String?
            var tag_last_pushed: String?
            var images: [Image]?
        }
        var results: [Row]?
    }

    static func parseTags(_ data: Data) throws -> [ImageTag] {
        let page = try JSONDecoder().decode(TagsPage.self, from: data)
        return (page.results ?? []).map { row in
            ImageTag(
                name: row.name,
                lastPushed: parseDate(row.tag_last_pushed) ?? parseDate(row.last_updated),
                fullSize: row.full_size,
                platforms: (row.images ?? []).compactMap { image in
                    guard let arch = image.architecture, !arch.isEmpty, arch != "unknown" else { return nil }
                    return ImageTag.Platform(os: image.os ?? "linux", architecture: arch, variant: image.variant, size: image.size)
                }
            )
        }
    }

    /// Docker Hub dates have fractional seconds ("2026-11-20T01:52:03.186066Z").
    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
