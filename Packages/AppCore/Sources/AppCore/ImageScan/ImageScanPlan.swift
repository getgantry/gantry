import Foundation

/// How Gantry gives one image to a scanner on one kind of host.
/// Both scanners refuse the OCI tar of `container image save` (its first
/// entry is `./`), so Apple images are unpacked first. See spec 011 research.
public enum ImageScanPlan: Sendable, Equatable {
    /// `container image save --platform`, unpack, scan the OCI layout.
    case appleArchive(reference: String, platform: String?)
    /// Save through the Docker engine of this Mac, scan the archive.
    case dockerArchive(reference: String)
    /// Scan the registry copy of the tag: the image is on another machine.
    case registry(reference: String, platform: String?)

    /// The host kinds the plan knows.
    public enum HostKind: Sendable, Equatable {
        case apple
        case localDocker
        case remoteDocker
    }

    /// The plan for an image, or nil when the image cannot be scanned on
    /// this host (an untagged image on an Apple or SSH host).
    public static func make(
        host: HostKind,
        id: String,
        repoTags: [String],
        os: String,
        architecture: String,
        fallbackArchitecture: String = ""
    ) -> ImageScanPlan? {
        let tag = repoTags.first { !$0.isEmpty && $0 != "<none>:<none>" && !$0.hasSuffix(":<none>") }
        let platform = platformString(os: os, architecture: architecture.isEmpty ? fallbackArchitecture : architecture)
        switch host {
        case .apple:
            return tag.map { .appleArchive(reference: $0, platform: platform) }
        case .localDocker:
            return .dockerArchive(reference: tag ?? id)
        case .remoteDocker:
            return tag.map { .registry(reference: $0, platform: platform) }
        }
    }

    /// `os/arch` for the CLI flags, or nil when the architecture is unknown.
    /// The OS defaults to `linux`; `aarch64` and `x86_64` become the OCI names.
    public static func platformString(os: String, architecture: String) -> String? {
        let arch = architecture.trimmingCharacters(in: .whitespaces).lowercased()
        guard !arch.isEmpty else { return nil }
        let normalized: String = switch arch {
        case "aarch64": "arm64"
        case "x86_64": "amd64"
        default: arch
        }
        let system = os.trimmingCharacters(in: .whitespaces).isEmpty ? "linux" : os.lowercased()
        return "\(system)/\(normalized)"
    }

    /// The image reference of the plan.
    public var reference: String {
        switch self {
        case .appleArchive(let reference, _), .dockerArchive(let reference), .registry(let reference, _):
            reference
        }
    }

    /// True when the scanner reads the registry copy instead of the local image.
    public var scansRegistryCopy: Bool {
        if case .registry = self { return true }
        return false
    }
}

/// What the scanner reads.
public enum ScanSource: Sendable, Equatable {
    /// An unpacked OCI image layout folder.
    case ociLayout(path: String)
    /// A `docker save` archive.
    case dockerArchive(path: String)
    /// A registry reference, with an optional `os/arch` platform.
    case registry(reference: String, platform: String?)
}
