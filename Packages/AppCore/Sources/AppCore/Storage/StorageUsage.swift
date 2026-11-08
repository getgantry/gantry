import Foundation

/// A part of the apple/container data root.
public enum StorageCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case images
    case containers
    case snapshots
    case volumes
    case kernels
    case other

    public var id: String { rawValue }

    /// The folder of the category under the data root; nil for `other`.
    public var folderName: String? {
        switch self {
        case .images: "content"
        case .containers: "containers"
        case .snapshots: "snapshots"
        case .volumes: "volumes"
        case .kernels: "kernels"
        case .other: nil
        }
    }

    public var title: String {
        switch self {
        case .images: String(localized: "Images", bundle: .module)
        case .containers: String(localized: "Containers", bundle: .module)
        case .snapshots: String(localized: "Snapshots", bundle: .module)
        case .volumes: String(localized: "Volumes", bundle: .module)
        case .kernels: String(localized: "Kernels", bundle: .module)
        case .other: String(localized: "Other", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .images: "square.stack.3d.up"
        case .containers: "shippingbox"
        case .snapshots: "camera.on.rectangle"
        case .volumes: "externaldrive"
        case .kernels: "cpu"
        case .other: "ellipsis.circle"
        }
    }
}

/// The size of a file tree: what is on the disk and what the files claim.
public struct StorageSize: Sendable, Equatable, Codable {
    /// Bytes that the disk gives to the files (sparse holes not counted).
    public var allocated: Int64
    /// The sum of the file lengths.
    public var apparent: Int64

    public init(allocated: Int64 = 0, apparent: Int64 = 0) {
        self.allocated = allocated
        self.apparent = apparent
    }

    public static func + (a: StorageSize, b: StorageSize) -> StorageSize {
        StorageSize(allocated: a.allocated + b.allocated, apparent: a.apparent + b.apparent)
    }
}

/// One named volume of an apple host and its disk image.
public struct StorageVolumeUsage: Sendable, Equatable, Identifiable, Codable {
    public var name: String
    public var size: StorageSize
    public var id: String { name }
}

/// What the data root holds.
public struct StorageUsage: Sendable, Equatable, Codable {
    public var root: String
    public var categories: [StorageCategory: StorageSize]
    public var volumes: [StorageVolumeUsage]

    public var total: StorageSize {
        categories.values.reduce(StorageSize(), +)
    }

    public func size(of category: StorageCategory) -> StorageSize {
        categories[category] ?? StorageSize()
    }
}

/// Measures file trees. The seam keeps tests off real disks.
public protocol StorageSizing: Sendable {
    /// The size of the file or folder at `path`, nil when it is missing.
    func size(of path: String) -> StorageSize?
    /// The names of the entries in a folder.
    func children(of path: String) -> [String]
}

/// Builds a ``StorageUsage`` from a data root.
public enum StorageUsageScanner {
    /// The folders that belong to `other`: everything not in a category.
    public static func scan(root: String, sizing: any StorageSizing) -> StorageUsage {
        let base = StoragePaths.normalized(root)
        var categories: [StorageCategory: StorageSize] = [:]
        let named = Set(StorageCategory.allCases.compactMap(\.folderName))
        for category in StorageCategory.allCases {
            guard let folder = category.folderName else { continue }
            categories[category] = sizing.size(of: base + "/" + folder) ?? StorageSize()
        }
        var other = StorageSize()
        for child in sizing.children(of: base) where !named.contains(child) {
            other = other + (sizing.size(of: base + "/" + child) ?? StorageSize())
        }
        categories[.other] = other

        let volumesFolder = base + "/volumes"
        let volumes = sizing.children(of: volumesFolder).sorted().map { name in
            StorageVolumeUsage(name: name, size: sizing.size(of: volumesFolder + "/" + name) ?? StorageSize())
        }
        return StorageUsage(root: base, categories: categories, volumes: volumes)
    }
}

/// Walks the file system with allocated sizes; does not follow links.
public struct FileSystemStorageSizing: StorageSizing {
    public init() {}

    public func size(of path: String) -> StorageSize? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isDirectory != true {
            return StorageSize(
                allocated: Int64(values.totalFileAllocatedSize ?? 0),
                apparent: Int64(values.fileSize ?? 0)
            )
        }
        var total = StorageSize()
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return total
        }
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total.allocated += Int64(v.totalFileAllocatedSize ?? 0)
            total.apparent += Int64(v.fileSize ?? 0)
        }
        return total
    }

    public func children(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
