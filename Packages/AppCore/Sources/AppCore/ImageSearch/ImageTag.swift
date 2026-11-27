import Foundation

/// One tag of a repository. Docker Hub gives the date, the size and the
/// platforms; the registry API v2 gives the name only.
public struct ImageTag: Sendable, Hashable, Identifiable {
    public struct Platform: Sendable, Hashable {
        public var os: String
        public var architecture: String
        public var variant: String?
        public var size: Int64?

        public init(os: String, architecture: String, variant: String? = nil, size: Int64? = nil) {
            self.os = os
            self.architecture = architecture
            self.variant = variant
            self.size = size
        }

        /// `os/arch[/variant]`.
        public var display: String {
            [os, architecture, variant].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "/")
        }
    }

    public var name: String
    public var lastPushed: Date?
    public var fullSize: Int64?
    public var platforms: [Platform]

    public var id: String { name }

    public init(name: String, lastPushed: Date? = nil, fullSize: Int64? = nil, platforms: [Platform] = []) {
        self.name = name
        self.lastPushed = lastPushed
        self.fullSize = fullSize
        self.platforms = platforms
    }

    /// The image of the tag for `platform` (`os/arch`), matched on OS and
    /// architecture. Nil when the tag has no platform list.
    public func image(for platform: String?) -> Platform? {
        guard let platform, let wanted = Self.split(platform) else { return nil }
        return platforms.first { $0.os.lowercased() == wanted.os && $0.architecture.lowercased() == wanted.arch }
    }

    /// False only when the tag lists its platforms and `platform` is not one.
    public func supports(_ platform: String?) -> Bool {
        guard platform != nil, !platforms.isEmpty else { return true }
        return image(for: platform) != nil
    }

    /// The size for `platform`, else the full size of the tag.
    public func size(for platform: String?) -> Int64? {
        image(for: platform)?.size ?? fullSize
    }

    static func split(_ platform: String) -> (os: String, arch: String)? {
        let parts = platform.lowercased().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }
}
