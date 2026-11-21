import Foundation

/// One row of `GET /images/search`: a Docker Hub repository.
public struct ImageSearchResult: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var starCount: Int
    public var isOfficial: Bool

    public var id: String { name }

    public init(name: String, description: String, starCount: Int, isOfficial: Bool) {
        self.name = name
        self.description = description
        self.starCount = starCount
        self.isOfficial = isOfficial
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case starCount = "star_count"
        case isOfficial = "is_official"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        starCount = try container.decodeIfPresent(Int.self, forKey: .starCount) ?? 0
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
    }
}

extension DockerClient {
    /// `GET /images/search?term=&limit=`. The daemon asks Docker Hub.
    public func searchImages(term: String, limit: Int = 25) async throws -> [ImageSearchResult] {
        try await getJSON("/images/search", query: [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit))
        ])
    }
}
