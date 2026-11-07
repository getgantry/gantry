import Foundation

/// The file system family of a mounted disk.
public enum StorageFileSystem: String, Sendable, Equatable, Codable {
    case apfs
    case hfs
    case exfat
    case fat
    case ntfs
    case network
    case other

    /// Maps a `statfs` / URL resource type name ("apfs", "msdos", "smbfs").
    public init(typeName: String) {
        switch typeName.lowercased() {
        case "apfs": self = .apfs
        case "hfs", "hfs+", "hfsplus": self = .hfs
        case "exfat": self = .exfat
        case "msdos", "fat", "fat32", "vfat": self = .fat
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs": self = .ntfs
        case "smbfs", "nfs", "afpfs", "webdav", "cifs", "macfuse_sshfs": self = .network
        default: self = .other
        }
    }

    /// True for the macOS file systems that keep sparse files, owners and
    /// extended attributes the way apple/container needs them.
    public var keepsUnixMetadata: Bool { self == .apfs || self == .hfs }
}

/// Where a disk is attached.
public enum StoragePlacement: String, Sendable, Equatable, Codable {
    case `internal`
    case external
    case removable
    case network
}

/// One mounted disk (a volume in Finder terms).
public struct StorageDisk: Sendable, Equatable, Identifiable, Codable {
    /// The mount point ("/" or "/Volumes/Data").
    public var mountPath: String
    /// The name Finder shows.
    public var name: String
    public var fileSystem: StorageFileSystem
    /// The raw type name ("apfs", "exfat").
    public var fileSystemName: String
    /// A readable format, for example "APFS" or "ExFAT".
    public var formatDescription: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var placement: StoragePlacement
    public var isReadOnly: Bool
    /// The disk is mounted with "Ignore ownership" (`noowners`).
    public var ignoresOwnership: Bool
    public var isBootDisk: Bool

    public var id: String { mountPath }

    public init(
        mountPath: String,
        name: String,
        fileSystemName: String,
        formatDescription: String? = nil,
        totalBytes: Int64,
        availableBytes: Int64,
        placement: StoragePlacement,
        isReadOnly: Bool = false,
        ignoresOwnership: Bool = false,
        isBootDisk: Bool = false
    ) {
        self.mountPath = mountPath
        self.name = name
        self.fileSystemName = fileSystemName
        self.fileSystem = StorageFileSystem(typeName: fileSystemName)
        self.formatDescription = formatDescription ?? fileSystemName.uppercased()
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.placement = placement
        self.isReadOnly = isReadOnly
        self.ignoresOwnership = ignoresOwnership
        self.isBootDisk = isBootDisk
    }

    /// True when `path` is on this disk (by mount point prefix).
    public func contains(path: String) -> Bool {
        let normalized = StoragePaths.normalized(path)
        if mountPath == "/" { return true }
        return normalized == mountPath || normalized.hasPrefix(mountPath + "/")
    }
}

/// Reads disk facts. The seam lets tests run without real disks.
public protocol StorageDiskReading: Sendable {
    /// Every mounted disk that a user can see (no system volumes).
    func mountedDisks() -> [StorageDisk]
    /// The disk that holds `path`, or nil when the path's disk is gone.
    func disk(containing path: String) -> StorageDisk?
}

extension StorageDiskReading {
    public func disk(containing path: String) -> StorageDisk? {
        StoragePaths.disk(containing: path, in: mountedDisks())
    }
}

/// Path helpers for disks under `/Volumes`.
public enum StoragePaths {
    public static func normalized(_ path: String) -> String {
        var value = (path as NSString).standardizingPath
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// The mount point of the external disk that `path` is under
    /// ("/Volumes/Disk" for "/Volumes/Disk/data"), or nil for the boot disk.
    public static func volumeMountPoint(of path: String) -> String? {
        let parts = normalized(path).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// The disk name of an external path ("Disk" for "/Volumes/Disk/data").
    public static func volumeName(of path: String) -> String? {
        volumeMountPoint(of: path).map { ($0 as NSString).lastPathComponent }
    }

    /// The disk with the longest mount point that holds `path`.
    public static func disk(containing path: String, in disks: [StorageDisk]) -> StorageDisk? {
        disks.filter { $0.contains(path: path) }.max { $0.mountPath.count < $1.mountPath.count }
    }

    /// True when `inner` is `outer` or inside it.
    public static func isInside(_ inner: String, _ outer: String) -> Bool {
        let a = normalized(inner), b = normalized(outer)
        return a == b || a.hasPrefix(b == "/" ? "/" : b + "/")
    }
}

/// Reads mounted disks from the file system (URL resource values and `statfs`).
public struct SystemStorageDiskReader: StorageDiskReading {
    public init() {}

    public func mountedDisks() -> [StorageDisk] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys, options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(Self.disk(at:))
    }

    public func disk(containing path: String) -> StorageDisk? {
        var url = URL(fileURLWithPath: path)
        // The path may not exist yet (a new folder): use the nearest parent.
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.volume else { return nil }
        // A missing /Volumes/X falls back to "/"; that is not the right disk.
        if StoragePaths.volumeMountPoint(of: path) != nil, volume.path == "/" { return nil }
        return Self.disk(at: volume)
    }

    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
        .volumeLocalizedFormatDescriptionKey, .volumeTypeNameKey
    ]

    static func disk(at url: URL) -> StorageDisk? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        var fs = statfs()
        let hasStat = statfs(url.path, &fs) == 0
        let typeName = values.volumeTypeName
            ?? (hasStat ? withUnsafePointer(to: fs.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            } : "other")
        let flags = hasStat ? UInt32(fs.f_flags) : 0
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return StorageDisk(
            mountPath: StoragePaths.normalized(url.path),
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            fileSystemName: typeName,
            formatDescription: values.volumeLocalizedFormatDescription,
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            availableBytes: available,
            placement: placement(values),
            isReadOnly: values.volumeIsReadOnly ?? false,
            ignoresOwnership: flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0,
            isBootDisk: values.volumeIsRootFileSystem ?? false
        )
    }

    static func placement(_ values: URLResourceValues) -> StoragePlacement {
        if values.volumeIsLocal == false { return .network }
        if values.volumeIsInternal == true { return .internal }
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true { return .removable }
        return .external
    }
}
