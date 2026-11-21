import Foundation

/// An image reference split as Docker splits it: registry, repository,
/// tag and digest. `nginx` is `docker.io/library/nginx:latest`.
public struct ImageReference: Hashable, Sendable {
    public var registry: String
    public var repository: String
    /// Nil only when the reference has a digest and no tag.
    public var tag: String?
    public var digest: String?

    public static let dockerHub = "docker.io"

    public init(registry: String, repository: String, tag: String?, digest: String? = nil) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Parses a reference. Nil for an empty text, an image id or a bad name.
    public static func parse(_ text: String) -> ImageReference? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !isImageID(rest), !rest.contains(" ") else { return nil }
        var digest: String?
        if let at = rest.firstIndex(of: "@") {
            digest = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
            guard digest?.contains(":") == true else { return nil }
        }
        var tag: String?
        if let colon = rest.lastIndex(of: ":"), !rest[rest.index(after: colon)...].contains("/") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
            guard tag?.isEmpty == false else { return nil }
        }
        var parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        var registry = dockerHub
        if parts.count > 1, isRegistryHost(parts[0]) {
            registry = parts.removeFirst()
        }
        if registry == "index.docker.io" || registry == "registry-1.docker.io" { registry = dockerHub }
        if registry == dockerHub, parts.count == 1 { parts.insert("library", at: 0) }
        let repository = parts.joined(separator: "/")
        guard repository == repository.lowercased() else { return nil }
        if tag == nil, digest == nil { tag = "latest" }
        return ImageReference(registry: registry, repository: repository, tag: tag, digest: digest)
    }

    /// `registry/repository`, the name without tag and digest.
    public var name: String { registry + "/" + repository }

    /// `registry/repository:tag` (or `@digest`), one key for one remote image.
    public var canonical: String {
        if let digest { return name + "@" + digest }
        return name + ":" + (tag ?? "latest")
    }

    /// The host for the registry HTTP API. Docker Hub has its own host.
    public var apiHost: String { registry == Self.dockerHub ? "registry-1.docker.io" : registry }

    /// A first path part is a registry when it has a dot, a port or is localhost.
    static func isRegistryHost(_ part: String) -> Bool {
        part.contains(".") || part.contains(":") || part == "localhost"
    }

    /// `sha256:…` or a bare 64-hex id.
    static func isImageID(_ text: String) -> Bool {
        if text.hasPrefix("sha256:") { return true }
        return text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}
