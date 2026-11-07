import Foundation
import DockerKit

/// Which disks under `/Volumes` are connected. The app fills it from
/// NSWorkspace mount notifications; the checks below are pure.
public struct DiskPresence: Sendable, Equatable {
    /// Mount points that are connected ("/Volumes/Disk").
    public var mounted: Set<String>

    public init(mounted: Set<String>) {
        self.mounted = Set(mounted.map(StoragePaths.normalized))
    }

    /// Reads the mount points under `/Volumes` now.
    public static func current(fileManager: FileManager = .default) -> DiskPresence {
        let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return DiskPresence(mounted: Set(urls.map(\.path).filter { $0.hasPrefix("/Volumes/") }))
    }

    /// True when the disk of `path` is connected. Paths outside `/Volumes`
    /// are on the boot disk and always count as connected.
    public func isConnected(_ path: String) -> Bool {
        guard let mountPoint = StoragePaths.volumeMountPoint(of: path) else { return true }
        return mounted.contains(mountPoint)
    }

    /// The name of the missing disk of `path`, or nil.
    public func missingDisk(for path: String) -> String? {
        isConnected(path) ? nil : StoragePaths.volumeName(of: path)
    }

    /// The host paths that a container mounts (bind mounts only).
    public static func hostSources(of container: ContainerSummary) -> [String] {
        container.mounts.map(\.source).filter { $0.hasPrefix("/") }
    }

    /// Names of the missing disks that `container` mounts from.
    public func missingDisks(for container: ContainerSummary, folderVolumes: [String: String] = [:]) -> [String] {
        var paths = Self.hostSources(of: container)
        for mount in container.mounts {
            if let name = mount.name ?? (mount.source.hasPrefix("/") ? nil : mount.source),
               let path = folderVolumes[name] {
                paths.append(path)
            }
        }
        var seen = Set<String>()
        return paths.compactMap(missingDisk(for:)).filter { seen.insert($0).inserted }
    }

    /// The containers that run with a bind mount from the disk at
    /// `mountPoint`; they must stop before the disk is ejected.
    public static func runningContainers(on mountPoint: String, in containers: [ContainerSummary]) -> [ContainerSummary] {
        let point = StoragePaths.normalized(mountPoint)
        return containers.filter { container in
            container.state.isRunning && hostSources(of: container).contains { StoragePaths.isInside($0, point) }
        }
    }
}

/// Why a host or a container cannot use its storage now.
public struct StorageBlock: Sendable, Equatable {
    /// Names of the disks that are not connected.
    public var disks: [String]

    public init(disks: [String]) { self.disks = disks }

    public var message: String {
        if disks.count == 1, let disk = disks.first {
            return String(localized: "The disk “\(disk)” is not connected.", bundle: .module)
        }
        let names = disks.map { "“\($0)”" }.joined(separator: ", ")
        return String(localized: "These disks are not connected: \(names).", bundle: .module)
    }

    /// The text for a container that cannot start.
    public var startMessage: String {
        String(localized: "\(message) Connect the disk, then start the container.", bundle: .module)
    }

    /// The text for an apple host whose data root is on a missing disk.
    public var hostMessage: String {
        String(localized: "\(message) The apple/container data is on this disk. Connect it, then start the services.", bundle: .module)
    }
}
