import Foundation

/// Decoded `X-Docker-Container-Path-Stat` header from the archive endpoints.
///
/// The daemon base64-encodes a JSON object describing a path inside a container.
public struct ContainerPathStat: Hashable, Codable, Sendable {
    public var name: String
    public var size: Int64
    /// Go `os.FileMode` bits. The high bits encode type (dir, symlink, etc.).
    public var mode: UInt32
    public var mtime: String
    public var linkTarget: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case mode
        case mtime
        case linkTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mode = try c.decodeIfPresent(UInt32.self, forKey: .mode) ?? 0
        mtime = try c.decodeIfPresent(String.self, forKey: .mtime) ?? ""
        linkTarget = try c.decodeIfPresent(String.self, forKey: .linkTarget) ?? ""
    }

    public init(name: String, size: Int64, mode: UInt32, mtime: String, linkTarget: String) {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
        self.linkTarget = linkTarget
    }

    // Go FileMode high bits (golang.org/pkg/os/#FileMode).
    private static let modeDir: UInt32 = 1 << 31
    private static let modeSymlink: UInt32 = 1 << 27

    public var isDirectory: Bool { mode & Self.modeDir != 0 }
    public var isSymlink: Bool { mode & Self.modeSymlink != 0 }
}

/// One entry produced by listing a directory inside a container.
public struct ContainerFileEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var modified: Date?

    public var id: String { name }

    public init(name: String, isDirectory: Bool, isSymlink: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
    }
}
