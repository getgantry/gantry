import Foundation

/// One entry of `GET /images/json`.
public struct ImageSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var parentID: String
    public var repoTags: [String]
    public var repoDigests: [String]
    public var created: Int64
    public var size: Int64
    public var sharedSize: Int64
    public var containers: Int
    public var labels: [String: String]
    /// Manifest descriptor (`Descriptor` on `/images/json?manifests=true`,
    /// Engine API 1.48+). Its platform names the image's architecture/OS when
    /// the daemon reports it; `architecture`/`os` below stay "" otherwise and
    /// `listImages()` fills them from a per-image inspect.
    public var descriptor: ImageDescriptor?

    /// CPU architecture of the image's platform (e.g. "amd64", "arm64").
    public var architecture: String { descriptor?.platform?.architecture ?? "" }
    /// OS of the image's platform (e.g. "linux"); empty when unknown.
    public var os: String { descriptor?.platform?.os ?? "" }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case parentID = "ParentId"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
        case created = "Created"
        case size = "Size"
        case sharedSize = "SharedSize"
        case containers = "Containers"
        case labels = "Labels"
        case descriptor = "Descriptor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID) ?? ""
        repoTags = try c.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        repoDigests = try c.decodeIfPresent([String].self, forKey: .repoDigests) ?? []
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sharedSize = try c.decodeIfPresent(Int64.self, forKey: .sharedSize) ?? -1
        containers = try c.decodeIfPresent(Int.self, forKey: .containers) ?? -1
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        descriptor = try? c.decodeIfPresent(ImageDescriptor.self, forKey: .descriptor)
    }

    /// First repo tag, or the short id with a `<none>` style fallback when untagged.
    public var displayName: String {
        if let tag = repoTags.first, tag != "<none>:<none>" {
            return tag
        }
        return "\(shortID) <none>"
    }

    /// Image id with the `sha256:` prefix stripped, truncated to 12 chars.
    public var shortID: String {
        let stripped = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id
        return String(stripped.prefix(12))
    }

    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }

    public var sizeDisplay: String { size.formatted(.byteCount(style: .file)) }

    /// `"linux/amd64"` style summary; omits the OS when the daemon omits it.
    public var platformDisplay: String { os.isEmpty ? architecture : "\(os)/\(architecture)" }
}

extension [ImageSummary] {
    /// Architecture by image id, skipping images whose platform the daemon
    /// didn't report (absent entries render no badge rather than a wrong one).
    public var architectureByImageID: [String: String] {
        Dictionary(
            compactMap { image in
                image.architecture.isEmpty ? nil : (image.id, image.architecture)
            },
            uniquingKeysWith: { _, second in second }
        )
    }
}

/// Manifest descriptor returned in `Descriptor` on `/images/json?manifests=true`
/// (Engine API 1.48+). Properties are optional on every level: older daemons
/// omit the descriptor entirely, and some entries carry no platform.
public struct ImageDescriptor: Codable, Hashable, Sendable {
    public var platform: ImagePlatform?

    enum CodingKeys: String, CodingKey {
        case platform = "platform"
    }

    public init(platform: ImagePlatform? = nil) {
        self.platform = platform
    }
}

/// Platform of an image: `architecture`/`os` from manifest descriptors and
/// `Architecture`/`Os` from image inspect — the two endpoints spell the same
/// fields differently, and one type answers both.
public struct ImagePlatform: Codable, Hashable, Sendable {
    public var architecture: String?
    public var os: String?

    public init(architecture: String? = nil, os: String? = nil) {
        self.architecture = architecture
        self.os = os
    }

    public init(from decoder: Decoder) throws {
        // Try the manifest descriptor's lowercase keys, then inspect's.
        let m = try decoder.container(keyedBy: ManifestKeys.self)
        architecture = try m.decodeIfPresent(String.self, forKey: .architecture)
            ?? m.decodeIfPresent(String.self, forKey: .inspectArchitecture)
        os = try m.decodeIfPresent(String.self, forKey: .os)
            ?? m.decodeIfPresent(String.self, forKey: .inspectOS)
    }

    enum ManifestKeys: String, CodingKey {
        case architecture, os
        case inspectArchitecture = "Architecture"
        case inspectOS = "Os"
    }
}
