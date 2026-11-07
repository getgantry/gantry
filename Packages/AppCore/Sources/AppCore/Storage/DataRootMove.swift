import Foundation
import DockerKit

/// Why a data root move cannot start or did not finish.
public enum DataRootMoveError: Error, LocalizedError, Sendable, Equatable {
    case sameLocation
    case destinationInsideSource
    case destinationNotEmpty(String)
    case diskRefused([StorageIssue])
    case verifyFailed([String])
    case servicesDidNotStart(String)
    case listingChanged(before: StorageListing, after: StorageListing)
    case activeRoot

    public var errorDescription: String? {
        switch self {
        case .sameLocation:
            String(localized: "The data is already in this location.", bundle: .module)
        case .destinationInsideSource:
            String(localized: "The new location cannot be inside the current data folder.", bundle: .module)
        case .destinationNotEmpty(let path):
            String(localized: "The folder \(path) already exists and is not empty. Remove it or choose a different disk.", bundle: .module)
        case .diskRefused(let issues):
            issues.map(\.message).joined(separator: " ")
        case .verifyFailed(let differences):
            String(localized: "The copy is not the same as the original (\(differences.prefix(3).joined(separator: ", "))). The original data was not changed.", bundle: .module)
        case .servicesDidNotStart(let message):
            String(localized: "The services did not start on the new location, so Gantry went back to the original data. \(message)", bundle: .module)
        case .listingChanged:
            String(localized: "After the move, the services did not list all containers, images and volumes, so Gantry went back to the original data.", bundle: .module)
        case .activeRoot:
            String(localized: "This folder is the data that the services use now.", bundle: .module)
        }
    }
}

/// How many resources the services list; compared before and after a move.
public struct StorageListing: Sendable, Equatable {
    public var containers: Int
    public var images: Int
    public var volumes: Int

    public init(containers: Int, images: Int, volumes: Int) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    /// True when nothing that was listed before is missing.
    public func covers(_ before: StorageListing) -> Bool {
        containers >= before.containers && images >= before.images && volumes >= before.volumes
    }
}

/// A checked plan to move the data root.
public struct DataRootMovePlan: Sendable, Equatable {
    public var source: String
    public var destination: String
    /// Bytes the copy needs on the destination disk.
    public var requiredBytes: Int64
    /// Warnings to show before the user confirms.
    public var warnings: [StorageIssue]

    /// The folder name of a data root on another disk.
    public static let folderName = "com.apple.container"

    /// Spare room on top of the copy: the services write logs and state.
    public static let marginBytes: Int64 = 1 << 30

    /// The data root folder for a disk: the default folder on the boot
    /// disk, `<disk>/com.apple.container` elsewhere.
    public static func destination(on disk: StorageDisk) -> String {
        disk.isBootDisk ? AppleDataRoot.defaultPath : disk.mountPath + "/" + folderName
    }

    /// Checks a move of `source` (`size` on disk) to `disk`.
    /// `isEmptyOrMissing` reports whether a folder is free to use.
    public static func make(
        source: String,
        size: StorageSize,
        disk: StorageDisk,
        destination: String? = nil,
        isEmptyOrMissing: (String) -> Bool
    ) -> Result<DataRootMovePlan, DataRootMoveError> {
        let target = StoragePaths.normalized(destination ?? Self.destination(on: disk))
        let from = StoragePaths.normalized(source)
        if target == from { return .failure(.sameLocation) }
        if StoragePaths.isInside(target, from) || StoragePaths.isInside(from, target) {
            return .failure(.destinationInsideSource)
        }
        if !isEmptyOrMissing(target) { return .failure(.destinationNotEmpty(target)) }
        // A copy within one disk shares no blocks across disks; count all.
        let required = size.allocated + marginBytes
        let check = StorageCheck.dataRoot(on: disk, requiredBytes: required)
        guard check.isAllowed else { return .failure(.diskRefused(check.blocking)) }
        return .success(DataRootMovePlan(
            source: from, destination: target, requiredBytes: required, warnings: check.warnings
        ))
    }
}

/// The steps of a move, in order.
public enum DataRootMoveStep: Int, Sendable, CaseIterable, Comparable {
    case listBefore
    case stopServices
    case copy
    case verify
    case switchRoot
    case startServices
    case checkListing

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .listBefore: String(localized: "Reading the current resources", bundle: .module)
        case .stopServices: String(localized: "Stopping the services", bundle: .module)
        case .copy: String(localized: "Copying the data", bundle: .module)
        case .verify: String(localized: "Verifying the copy", bundle: .module)
        case .switchRoot: String(localized: "Switching to the new location", bundle: .module)
        case .startServices: String(localized: "Starting the services", bundle: .module)
        case .checkListing: String(localized: "Checking containers, images and volumes", bundle: .module)
        }
    }
}

/// Progress of a move: the step, and bytes copied during `copy`.
public struct DataRootMoveProgress: Sendable, Equatable {
    public var step: DataRootMoveStep
    public var copiedBytes: Int64?
    public var totalBytes: Int64?

    public var fraction: Double? {
        guard let copiedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(copiedBytes) / Double(totalBytes), 1)
    }
}

/// The side effects of a move. Tests use a fake.
public protocol DataRootMoveEnvironment: Sendable {
    func listing() async throws -> StorageListing
    func stopServices() async throws
    func startServices(_ root: AppleDataRoot) async throws
    /// Copies a tree and keeps sparse files, owners, modes and xattrs.
    func copyTree(from source: String, to destination: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func manifest(of path: String) async throws -> TreeManifest
    func removeTree(_ path: String) async throws
    func saveRoot(_ root: AppleDataRoot) throws
}

/// Runs a ``DataRootMovePlan``. The source stays untouched; a failure or a
/// cancel before the switch removes the partial copy and starts the
/// services on the old root again.
public struct DataRootMover: Sendable {
    public let environment: any DataRootMoveEnvironment

    public init(environment: any DataRootMoveEnvironment) {
        self.environment = environment
    }

    /// Moves the data. Returns the old root, which the user can delete later.
    @discardableResult
    public func run(
        _ plan: DataRootMovePlan,
        totalBytes: Int64,
        progress: @escaping @Sendable (DataRootMoveProgress) -> Void
    ) async throws -> String {
        let env = environment
        let oldRoot = AppleDataRoot(path: plan.source)
        let newRoot = AppleDataRoot(path: plan.destination)

        progress(.init(step: .listBefore))
        let before = try await env.listing()
        try Task.checkCancellation()

        progress(.init(step: .stopServices))
        try await env.stopServices()

        do {
            progress(.init(step: .copy, copiedBytes: 0, totalBytes: totalBytes))
            try await env.copyTree(from: plan.source, to: plan.destination) { bytes in
                progress(.init(step: .copy, copiedBytes: bytes, totalBytes: totalBytes))
            }
            try Task.checkCancellation()

            progress(.init(step: .verify))
            let original = try await env.manifest(of: plan.source)
            let copy = try await env.manifest(of: plan.destination)
            let differences = original.differences(from: copy)
            guard differences.isEmpty else { throw DataRootMoveError.verifyFailed(differences) }
            // The last point where a cancel is honoured.
            try Task.checkCancellation()
        } catch {
            await Self.restore(env, old: oldRoot, removing: plan.destination)
            throw error
        }

        progress(.init(step: .switchRoot))
        try env.saveRoot(newRoot)

        progress(.init(step: .startServices))
        do {
            try await Self.detached { try await env.startServices(newRoot) }
        } catch {
            await Self.rollBack(env, old: oldRoot, removing: plan.destination)
            throw DataRootMoveError.servicesDidNotStart((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        progress(.init(step: .checkListing))
        let after = try? await Self.detached { try await env.listing() }
        guard let after, after.covers(before) else {
            await Self.rollBack(env, old: oldRoot, removing: plan.destination)
            throw DataRootMoveError.listingChanged(before: before, after: after ?? StorageListing(containers: 0, images: 0, volumes: 0))
        }
        return plan.source
    }

    /// Before the switch: drop the partial copy, start the old services.
    static func restore(_ env: any DataRootMoveEnvironment, old: AppleDataRoot, removing path: String) async {
        try? await detached { try await env.removeTree(path) }
        try? await detached { try await env.startServices(old) }
    }

    /// After the switch: store the old root again, then restore.
    static func rollBack(_ env: any DataRootMoveEnvironment, old: AppleDataRoot, removing path: String) async {
        try? await detached { try await env.stopServices() }
        try? env.saveRoot(old)
        await restore(env, old: old, removing: path)
    }

    /// Runs clean-up work outside the cancelled task, so it still runs.
    static func detached<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }

    /// Deletes an old data root after a move. Refuses the active root and
    /// any folder that contains it or is inside it.
    public func deleteOldRoot(_ path: String, activeRoot: String) async throws {
        if StoragePaths.isInside(path, activeRoot) || StoragePaths.isInside(activeRoot, path) {
            throw DataRootMoveError.activeRoot
        }
        try await environment.removeTree(path)
    }
}

/// The structure of a file tree, for comparing a copy with its original.
public struct TreeManifest: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case file
        case directory
        case symlink
    }

    public struct Entry: Sendable, Equatable {
        public var kind: Kind
        /// File length; 0 for folders.
        public var size: Int64
        public var linkTarget: String?

        public init(kind: Kind, size: Int64 = 0, linkTarget: String? = nil) {
            self.kind = kind
            self.size = size
            self.linkTarget = linkTarget
        }
    }

    /// Entries by path relative to the tree root. Sockets are left out:
    /// `cp` does not copy them and the services make them again.
    public var entries: [String: Entry]

    public init(entries: [String: Entry]) { self.entries = entries }

    /// Paths that are missing or not the same in `copy`, sorted.
    public func differences(from copy: TreeManifest) -> [String] {
        var result: [String] = []
        for (path, entry) in entries where copy.entries[path] != entry {
            result.append(path)
        }
        for path in copy.entries.keys where entries[path] == nil {
            result.append(path)
        }
        return result.sorted()
    }

    /// Reads a tree from the file system without following links. Paths
    /// come from the enumerator as relative paths, so a root reached
    /// through a link (/var is /private/var) gives the same keys.
    public static func read(_ root: String) throws -> TreeManifest {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else { return TreeManifest(entries: [:]) }
        var entries: [String: Entry] = [:]
        while let relative = walker.nextObject() as? String {
            let attributes = try walker.fileAttributes ?? fm.attributesOfItem(atPath: root + "/" + relative)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: entries[relative] = Entry(kind: .directory)
            case .typeRegular?: entries[relative] = Entry(kind: .file, size: (attributes[.size] as? Int64) ?? 0)
            case .typeSymbolicLink?:
                let target = try? fm.destinationOfSymbolicLink(atPath: root + "/" + relative)
                entries[relative] = Entry(kind: .symlink, linkTarget: target)
            default: continue
            }
        }
        return TreeManifest(entries: entries)
    }
}

/// Runs a data root move as a long operation with progress and Cancel.
@MainActor
public enum DataRootMoveOperation {
    @discardableResult
    public static func start(
        _ plan: DataRootMovePlan,
        totalBytes: Int64,
        center: OperationCenter,
        hostName: String?,
        environment: any DataRootMoveEnvironment,
        onFinish: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> LongOperation {
        center.run(
            .storage,
            title: String(localized: "Move container data to \(plan.destination)", bundle: .module),
            host: hostName,
            cancelConfirmation: String(localized: "Stop the move? The original data stays in use.", bundle: .module)
        ) { operation in
            do {
                let old = try await DataRootMover(environment: environment).run(plan, totalBytes: totalBytes) { progress in
                    Task { @MainActor in
                        var text = progress.step.title
                        if let copied = progress.copiedBytes, let total = progress.totalBytes {
                            text += " – \(StorageFormat.bytes(copied)) / \(StorageFormat.bytes(total))"
                        }
                        operation.update(progress: text, fraction: progress.fraction)
                        if operation.logTail(1).last != progress.step.title {
                            operation.append(log: progress.step.title)
                        }
                    }
                }
                OldDataRootRecord.save(old)
                onFinish(true)
                return String(localized: "The data is now in \(plan.destination).", bundle: .module)
            } catch {
                onFinish(false)
                throw error
            }
        }
    }
}
