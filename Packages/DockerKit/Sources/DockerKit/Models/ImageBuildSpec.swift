import Foundation

/// A request to build an image from a local context directory.
///
/// This is a Gantry-internal shape (not Docker's multipart `/build` API): it
/// carries a filesystem path that CLI-backed transports (apple/container) feed
/// straight to `container build`. The real Docker daemon does not handle this
/// route, so it is only issued against apple/container hosts (the Compose
/// runner, which is the sole caller, gates on host kind).
public struct ImageBuildSpec: Codable, Sendable, Equatable {
    /// Absolute path to the build context directory.
    public var contextPath: String
    /// Path to the Dockerfile, relative to the context (default `Dockerfile`).
    public var dockerfile: String?
    /// Image tag to apply to the built image (e.g. `myproject-api:latest`).
    public var tag: String
    /// `--build-arg` values.
    public var buildArgs: [String: String]
    /// `--target` build stage.
    public var target: String?
    /// Labels to set on the built image.
    public var labels: [String: String]
    /// Skip the build cache.
    public var noCache: Bool

    enum CodingKeys: String, CodingKey {
        case contextPath = "ContextPath"
        case dockerfile = "Dockerfile"
        case tag = "Tag"
        case buildArgs = "BuildArgs"
        case target = "Target"
        case labels = "Labels"
        case noCache = "NoCache"
    }

    public init(
        contextPath: String,
        dockerfile: String? = nil,
        tag: String,
        buildArgs: [String: String] = [:],
        target: String? = nil,
        labels: [String: String] = [:],
        noCache: Bool = false
    ) {
        self.contextPath = contextPath
        self.dockerfile = dockerfile
        self.tag = tag
        self.buildArgs = buildArgs
        self.target = target
        self.labels = labels
        self.noCache = noCache
    }
}
