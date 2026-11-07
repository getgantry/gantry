import Foundation
import DockerKit

/// What the Storage pane shows for an apple host.
public struct StorageOverview: Sendable, Equatable {
    /// The root that Gantry starts the services with.
    public var configuredRoot: AppleDataRoot
    /// The root that the running services report, when they run.
    public var serviceRoot: String?
    /// The disk of the root; nil when the disk is not connected.
    public var disk: StorageDisk?
    public var usage: StorageUsage?

    /// True when the services run on a different root than Gantry starts.
    public var rootMismatch: Bool {
        guard let serviceRoot else { return false }
        return StoragePaths.normalized(serviceRoot) != StoragePaths.normalized(configuredRoot.effectivePath)
    }

    /// Reads the overview off the main thread.
    public static func load(
        serviceRoot: String?,
        store: AppleDataRootStore = .shared,
        disks: any StorageDiskReading = SystemStorageDiskReader(),
        sizing: any StorageSizing = FileSystemStorageSizing()
    ) async -> StorageOverview {
        let root = store.load()
        return await Task.detached {
            let path = root.effectivePath
            let disk = disks.disk(containing: path)
            let usage = disk == nil ? nil : StorageUsageScanner.scan(root: path, sizing: sizing)
            return StorageOverview(configuredRoot: root, serviceRoot: serviceRoot, disk: disk, usage: usage)
        }.value
    }

    /// Disks that can take a data root, with the result of the check.
    public static func moveTargets(
        size: StorageSize,
        source: String,
        disks: any StorageDiskReading = SystemStorageDiskReader(),
        isEmptyOrMissing: @escaping @Sendable (String) -> Bool = StorageOverview.isEmptyOrMissing
    ) async -> [(disk: StorageDisk, plan: Result<DataRootMovePlan, DataRootMoveError>)] {
        await Task.detached {
            disks.mountedDisks()
                .filter { !$0.isReadOnly || $0.isBootDisk }
                .sorted { ($0.isBootDisk ? 0 : 1, $0.name) < ($1.isBootDisk ? 0 : 1, $1.name) }
                .map { ($0, DataRootMovePlan.make(source: source, size: size, disk: $0, isEmptyOrMissing: isEmptyOrMissing)) }
        }.value
    }

    /// True when nothing is at `path`, or it is an empty folder.
    @Sendable public static func isEmptyOrMissing(_ path: String) -> Bool {
        let items = try? FileManager.default.contentsOfDirectory(atPath: path)
        guard let items else { return !FileManager.default.fileExists(atPath: path) }
        return items.allSatisfy { $0 == ".DS_Store" }
    }
}

/// Remembers the old data root after a move, so the pane can offer to
/// delete it later.
public enum OldDataRootRecord {
    public static let key = "storage.oldDataRoot"

    public static func load(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    public static func save(_ path: String?, _ defaults: UserDefaults = .standard) {
        defaults.set(path, forKey: key)
    }
}
