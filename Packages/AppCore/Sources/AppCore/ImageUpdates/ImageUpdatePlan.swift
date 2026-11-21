import Foundation
import DockerKit

/// Whether a container runs the newest image of its tag.
public enum ImageUpdateStatus: Equatable, Sendable {
    case upToDate
    case updateAvailable
}

/// The pure rules of the image update check (spec 017).
public enum ImageUpdatePlan {
    /// What to check for one container: the remote reference and the digest
    /// of the image that the container runs.
    public struct Target: Equatable, Sendable {
        public var reference: ImageReference
        public var localDigest: String

        /// The cache key: one remote image.
        public var key: String { reference.canonical }
    }

    /// The target of `container`, or nil when Gantry does not check it: an
    /// image id, a digest-pinned reference, or (Docker) an image with no
    /// RepoDigests for the repository, such as a local build.
    public static func target(for container: ContainerSummary, images: [ImageSummary], isApple: Bool) -> Target? {
        guard let reference = ImageReference.parse(container.image), reference.digest == nil else { return nil }
        if isApple {
            // Apple images have no RepoDigests; the summary ImageID is the
            // descriptor digest of the image that the container runs.
            guard container.imageID.hasPrefix("sha256:") else { return nil }
            return Target(reference: reference, localDigest: container.imageID)
        }
        guard let image = images.first(where: { $0.id == container.imageID }),
              let digest = repoDigest(of: image, for: reference) else { return nil }
        return Target(reference: reference, localDigest: digest)
    }

    /// The digest in `RepoDigests` (`nginx@sha256:…`) for the repository of `reference`.
    static func repoDigest(of image: ImageSummary, for reference: ImageReference) -> String? {
        for entry in image.repoDigests {
            guard let parsed = ImageReference.parse(entry), parsed.name == reference.name,
                  let digest = parsed.digest else { continue }
            return digest
        }
        return nil
    }

    /// The status for a target and the remote digest; nil when not known.
    public static func status(of target: Target?, remoteDigest: String?) -> ImageUpdateStatus? {
        guard let target, let remoteDigest else { return nil }
        return target.localDigest == remoteDigest ? .upToDate : .updateAvailable
    }

    // MARK: - Recreate on the new image

    /// The environment that the user set: entries that are the same in the
    /// old image are left out, so the new image gives its own values.
    public static func userEnvironment(container: [String], image: [String]) -> [String] {
        let defaults = Set(image)
        return container.filter { !defaults.contains($0) }
    }

    /// The command, or nil when it is the command of the old image.
    public static func userCommand(container: [String]?, image: [String]?) -> [String]? {
        guard let container, container != (image ?? []) else { return nil }
        return container
    }

    /// `Config.Env` and `Config.Cmd` of an image inspect body (Docker, and the
    /// body that the Apple transport makes).
    public static func imageDefaults(fromInspect data: Data) -> (env: [String], cmd: [String]?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["Config"] as? [String: Any] else { return ([], nil) }
        return ((config["Env"] as? [String]) ?? [], config["Cmd"] as? [String])
    }
}
