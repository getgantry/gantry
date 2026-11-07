import Foundation
import DockerKit

/// One side of a volume copy.
public enum VolumeEndpoint: Sendable, Equatable, Hashable {
    /// A named volume of the engine.
    case named(String)
    /// A folder on a disk (a folder volume or any bind source).
    case folder(String)

    /// The `-v` source: the volume name or the folder path.
    public var mountSource: String {
        switch self {
        case .named(let name): name
        case .folder(let path): StoragePaths.normalized(path)
        }
    }
}

/// A short-lived helper container that does file work on mounts.
public struct HelperJob: Sendable, Equatable {
    public struct Mount: Sendable, Equatable {
        public var source: String
        public var target: String
        public var readOnly: Bool

        public var spec: String { "\(source):\(target)" + (readOnly ? ":ro" : "") }
    }

    /// A small image with `sh`, `cp` and `tar`.
    public static let defaultImage = "docker.io/library/alpine:3.20"

    public var image: String = HelperJob.defaultImage
    public var mounts: [Mount]
    /// A fixed `sh -c` script; values come in as `$1`, `$2`, so no
    /// file name is ever parsed as shell code.
    public var script: String
    public var arguments: [String] = []

    /// The `container run` arguments for an apple host.
    public func appleArguments(name: String) -> [String] {
        var result = ["run", "--rm", "--name", name]
        for mount in mounts { result += ["-v", mount.spec] }
        result += [image, "sh", "-c", script, "sh"] + arguments
        return result
    }

    /// The create request for a Docker host. The caller waits for the exit
    /// and removes the container.
    public func dockerRequest(name: String) -> ContainerCreateRequest {
        ContainerCreateRequest(
            image: image,
            cmd: ["sh", "-c", script, "sh"] + arguments,
            binds: mounts.map(\.spec),
            labels: [HelperJob.label: "1"],
            name: name
        )
    }

    /// Marks helper containers, so a left-over one is easy to find.
    public static let label = "app.gantry.storage-helper"

    /// A unique container name for a helper.
    public static func containerName(_ purpose: String, id: UUID = UUID()) -> String {
        "gantry-\(purpose)-" + id.uuidString.prefix(8).lowercased()
    }
}

/// Plans of volume copies, exports and imports.
public enum VolumeTransferPlan {
    /// Copies every file, with owners and modes, from one side to the other.
    public static func copy(from source: VolumeEndpoint, to destination: VolumeEndpoint) -> HelperJob {
        HelperJob(
            mounts: [
                .init(source: source.mountSource, target: "/from", readOnly: true),
                .init(source: destination.mountSource, target: "/to", readOnly: false)
            ],
            script: "cp -a /from/. /to/"
        )
    }

    /// Writes the volume as `<folder>/<fileName>` (a tar archive).
    public static func exportTar(_ volume: VolumeEndpoint, toFolder folder: String, fileName: String) -> HelperJob {
        HelperJob(
            mounts: [
                .init(source: volume.mountSource, target: "/from", readOnly: true),
                .init(source: StoragePaths.normalized(folder), target: "/out", readOnly: false)
            ],
            script: "tar -cf \"/out/$1\" -C /from .",
            arguments: [fileName]
        )
    }

    /// Unpacks the tar archive at `file` into the volume.
    public static func importTar(file: String, into volume: VolumeEndpoint) -> HelperJob {
        let path = StoragePaths.normalized(file)
        return HelperJob(
            mounts: [
                .init(source: (path as NSString).deletingLastPathComponent, target: "/in", readOnly: true),
                .init(source: volume.mountSource, target: "/to", readOnly: false)
            ],
            script: "tar -xf \"/in/$1\" -C /to",
            arguments: [(path as NSString).lastPathComponent]
        )
    }

    /// A default archive name: `<volume>-<yyyyMMdd-HHmmss>.tar`.
    public static func archiveName(for volume: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(volume)-\(formatter.string(from: date)).tar"
    }

    /// The containers that mount `volume` (by name or by folder path).
    public static func users(of volume: VolumeEndpoint, in containers: [ContainerSummary]) -> [ContainerSummary] {
        containers.filter { container in
            container.mounts.contains { mount in
                switch volume {
                case .named(let name):
                    mount.name == name || mount.source == name
                case .folder(let path):
                    StoragePaths.normalized(mount.source) == StoragePaths.normalized(path)
                }
            }
        }
    }

    /// The binds of a container with every mount of `old` changed to `new`.
    /// Bind strings are `source:target[:mode]`.
    public static func replacingSource(in binds: [String], old: VolumeEndpoint, new: VolumeEndpoint) -> [String] {
        binds.map { bind in
            var parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let first = parts.first else { return bind }
            let matches: Bool
            switch old {
            case .named(let name): matches = first == name
            case .folder(let path): matches = StoragePaths.normalized(first) == StoragePaths.normalized(path)
            }
            guard matches else { return bind }
            parts[0] = new.mountSource
            return parts.joined(separator: ":")
        }
    }
}

/// Image archives on a disk.
public enum ImageArchive {
    /// `container image save -o <path> <refs>`.
    public static func appleSaveArguments(references: [String], to path: String) -> [String] {
        ["image", "save", "--output", StoragePaths.normalized(path)] + references
    }

    /// `container image load -i <path>`.
    public static func appleLoadArguments(from path: String) -> [String] {
        ["image", "load", "--input", StoragePaths.normalized(path)]
    }

    /// A default archive name for an image reference ("nginx-latest.tar").
    public static func archiveName(for reference: String) -> String {
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        let cleaned = last.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (name.isEmpty ? "image" : name) + ".tar"
    }
}
