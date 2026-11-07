import Foundation

/// One finding about a disk for a storage use.
public enum StorageIssue: Sendable, Equatable, Hashable {
    /// exFAT, FAT or NTFS: no sparse files, owners or permissions.
    case unsupportedFileSystem(String)
    case networkDisk
    case readOnly
    /// The disk can be ejected or unplugged.
    case removable
    /// The disk ignores owners: files show as the current user's.
    case ignoresOwnership
    case notEnoughSpace(needed: Int64, available: Int64)
    /// The disk is not connected.
    case missing(String)

    /// A refusal stops the action; a warning only informs.
    public var isBlocking: Bool {
        switch self {
        case .unsupportedFileSystem, .readOnly, .notEnoughSpace, .missing: true
        case .networkDisk, .removable, .ignoresOwnership: false
        }
    }

    public var message: String {
        switch self {
        case .unsupportedFileSystem(let name):
            String(localized: "The disk uses \(name). Use a disk with APFS or Mac OS Extended. \(name) does not keep sparse files, owners and permissions.", bundle: .module)
        case .networkDisk:
            String(localized: "This is a network disk. It can be slow, and containers stop when the connection is lost.", bundle: .module)
        case .readOnly:
            String(localized: "The disk is read-only.", bundle: .module)
        case .removable:
            String(localized: "This disk can be disconnected. Stop the containers before you eject it.", bundle: .module)
        case .ignoresOwnership:
            String(localized: "The disk ignores ownership. All files show as yours, so a container that needs other owners can fail.", bundle: .module)
        case .notEnoughSpace(let needed, let available):
            String(localized: "Not enough free space: \(StorageFormat.bytes(needed)) is necessary, \(StorageFormat.bytes(available)) is free.", bundle: .module)
        case .missing(let name):
            String(localized: "The disk “\(name)” is not connected.", bundle: .module)
        }
    }
}

/// The result of a disk check: refusals and warnings, in a fixed order.
public struct StorageCheck: Sendable, Equatable {
    public var issues: [StorageIssue]

    public init(issues: [StorageIssue] = []) { self.issues = issues }

    public var blocking: [StorageIssue] { issues.filter(\.isBlocking) }
    public var warnings: [StorageIssue] { issues.filter { !$0.isBlocking } }
    public var isAllowed: Bool { blocking.isEmpty }

    /// A disk for the whole apple/container data root. Disk images need
    /// sparse files, owners and xattrs, so only APFS and HFS+ pass.
    public static func dataRoot(on disk: StorageDisk, requiredBytes: Int64) -> StorageCheck {
        var issues: [StorageIssue] = []
        let isNetwork = disk.fileSystem == .network || disk.placement == .network
        if isNetwork {
            issues.append(.networkDisk)
        } else if !disk.fileSystem.keepsUnixMetadata {
            issues.append(.unsupportedFileSystem(disk.formatDescription))
        }
        if disk.isReadOnly { issues.append(.readOnly) }
        if requiredBytes > disk.availableBytes {
            issues.append(.notEnoughSpace(needed: requiredBytes, available: disk.availableBytes))
        }
        if disk.placement == .removable || disk.placement == .external { issues.append(.removable) }
        return StorageCheck(issues: issues)
    }

    /// A disk for a folder that containers mount (bind mount or folder
    /// volume). Other file systems work, but with warnings.
    public static func bindMount(on disk: StorageDisk?, path: String) -> StorageCheck {
        guard let disk else {
            return StorageCheck(issues: [.missing(StoragePaths.volumeName(of: path) ?? path)])
        }
        var issues: [StorageIssue] = []
        if disk.placement == .network || disk.fileSystem == .network { issues.append(.networkDisk) }
        if disk.isBootDisk || disk.placement == .internal { return StorageCheck(issues: issues) }
        if disk.placement == .removable || disk.placement == .external { issues.append(.removable) }
        if disk.fileSystem != .network, !disk.fileSystem.keepsUnixMetadata {
            issues.append(.ignoresOwnership)
        } else if disk.ignoresOwnership {
            issues.append(.ignoresOwnership)
        }
        return StorageCheck(issues: issues)
    }

    /// A disk for a new folder volume: like a bind mount, and it must be
    /// writable.
    public static func folderVolume(on disk: StorageDisk?, path: String) -> StorageCheck {
        var check = bindMount(on: disk, path: path)
        if disk?.isReadOnly == true { check.issues.insert(.readOnly, at: 0) }
        return check
    }
}

/// Byte formatting shared by the storage texts.
public enum StorageFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
