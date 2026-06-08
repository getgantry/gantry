import Foundation

/// A single member to be written into a ustar archive by ``TarWriter``.
public struct TarEntry: Sendable {
    /// Path inside the archive (e.g. `dir/file.txt`). Directories conventionally
    /// end in a trailing slash, but ``TarWriter`` adds one for directory members
    /// automatically if missing.
    public var name: String
    /// File contents. `nil` (or empty) for directories.
    public var data: Data?
    /// Whether this member is a directory (typeflag `5`) rather than a file (`0`).
    public var isDirectory: Bool
    /// Permission bits stored in the octal `mode` field.
    public var mode: UInt16
    /// Modification time recorded in the header.
    public var modificationDate: Date

    public init(
        name: String,
        data: Data? = nil,
        isDirectory: Bool = false,
        mode: UInt16 = 0o644,
        modificationDate: Date = Date()
    ) {
        self.name = name
        self.data = data
        self.isDirectory = isDirectory
        self.mode = mode
        self.modificationDate = modificationDate
    }
}

/// Builds in-memory ustar (`POSIX.1`) archives — the inverse of ``TarReader``.
///
/// Each member is a 512-byte header followed by its payload padded to a
/// 512-byte boundary; the archive ends with two zero blocks. Names longer than
/// 100 bytes are emitted as a GNU long-name (`L`) extension entry preceding the
/// real header, which ``TarReader`` understands.
public enum TarWriter {
    private static let blockSize = 512
    private static let nameFieldLength = 100
    /// Sentinel name GNU `tar` uses for the long-name extension member.
    private static let gnuLongNameMarker = "././@LongLink"

    /// Packs `entries` into a single ustar archive.
    public static func archive(entries: [TarEntry]) -> Data {
        var archive = Data()
        for entry in entries {
            appendMember(entry, to: &archive)
        }
        // Two zero blocks terminate the archive.
        archive.append(Data(repeating: 0, count: blockSize * 2))
        return archive
    }

    /// Convenience: packs one file into a single-entry archive.
    public static func singleFile(name: String, contents: Data) -> Data {
        archive(entries: [TarEntry(name: name, data: contents)])
    }

    /// Reads a file or directory tree from disk into a ustar archive,
    /// preserving relative paths under `url`'s last path component and the
    /// executable bit of regular files.
    ///
    /// - Parameters:
    ///   - url: A file or directory on the local filesystem.
    ///   - recursive: When `url` is a directory, whether to descend into it.
    ///     Ignored for plain files.
    public static func archiveFileURL(_ url: URL, recursive: Bool) throws -> Data {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let rootName = url.lastPathComponent
        var entries: [TarEntry] = []

        if isDir.boolValue {
            entries.append(directoryEntry(named: rootName, url: url, fm: fm))
            if recursive {
                try appendTree(at: url, archivePrefix: rootName, into: &entries, fm: fm)
            }
        } else {
            entries.append(try fileEntry(named: rootName, url: url, fm: fm))
        }

        return archive(entries: entries)
    }

    /// Packs the *contents* of a directory at the archive root (no enclosing
    /// directory component), the shape Docker's `/build` endpoint expects for a
    /// build context. Paths matched by `ignore` are skipped; an ignored
    /// directory is pruned without descending into it.
    ///
    /// - Parameters:
    ///   - directory: The build context directory on disk.
    ///   - ignore: A `.dockerignore` matcher, or nil to include everything.
    public static func archiveDirectoryContents(
        _ directory: URL,
        ignore: DockerIgnore? = nil
    ) throws -> Data {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        var entries: [TarEntry] = []
        try appendContextTree(at: directory, archivePrefix: "", into: &entries, fm: fm, ignore: ignore)
        return archive(entries: entries)
    }

    /// Like ``appendTree`` but rooted at the archive top (no enclosing
    /// directory) and honouring a `.dockerignore` matcher.
    private static func appendContextTree(
        at directory: URL,
        archivePrefix: String,
        into entries: inout [TarEntry],
        fm: FileManager,
        ignore: DockerIgnore?
    ) throws {
        // Include hidden files: a build context legitimately needs .git-ignored
        // dotfiles like .env or .npmrc; exclusion is `.dockerignore`'s job.
        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let name = child.lastPathComponent
            let archivePath = archivePrefix.isEmpty ? name : archivePrefix + "/" + name
            if ignore?.excludes(archivePath) == true { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                entries.append(directoryEntry(named: archivePath, url: child, fm: fm))
                try appendContextTree(
                    at: child,
                    archivePrefix: archivePath,
                    into: &entries,
                    fm: fm,
                    ignore: ignore
                )
            } else {
                entries.append(try fileEntry(named: archivePath, url: child, fm: fm))
            }
        }
    }

    // MARK: - Disk traversal

    private static func appendTree(
        at directory: URL,
        archivePrefix: String,
        into entries: inout [TarEntry],
        fm: FileManager
    ) throws {
        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            let name = child.lastPathComponent
            let archivePath = archivePrefix + "/" + name
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                entries.append(directoryEntry(named: archivePath, url: child, fm: fm))
                try appendTree(at: child, archivePrefix: archivePath, into: &entries, fm: fm)
            } else {
                entries.append(try fileEntry(named: archivePath, url: child, fm: fm))
            }
        }
    }

    private static func fileEntry(named name: String, url: URL, fm: FileManager) throws -> TarEntry {
        let data = try Data(contentsOf: url)
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let posix = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        // Keep only the permission bits; round to a sane default if unreadable.
        let mode = (posix & 0o777) == 0 ? 0o644 : (posix & 0o777)
        let mtime = (attributes?[.modificationDate] as? Date) ?? Date()
        return TarEntry(name: name, data: data, isDirectory: false, mode: mode, modificationDate: mtime)
    }

    private static func directoryEntry(named name: String, url: URL, fm: FileManager) -> TarEntry {
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let posix = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o755
        let mode = (posix & 0o777) == 0 ? 0o755 : (posix & 0o777)
        let mtime = (attributes?[.modificationDate] as? Date) ?? Date()
        return TarEntry(name: name, data: nil, isDirectory: true, mode: mode, modificationDate: mtime)
    }

    // MARK: - Member encoding

    private static func appendMember(_ entry: TarEntry, to archive: inout Data) {
        var name = entry.name
        if entry.isDirectory, !name.hasSuffix("/") {
            name += "/"
        }

        let nameBytes = Array(name.utf8)
        if nameBytes.count > nameFieldLength {
            appendLongNameExtension(name: name, to: &archive)
        }

        let payload = entry.isDirectory ? Data() : (entry.data ?? Data())
        let header = makeHeader(
            name: name,
            size: payload.count,
            mode: entry.mode,
            mtime: entry.modificationDate,
            typeFlag: entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        )
        archive.append(header)
        archive.append(payload)
        appendPadding(for: payload.count, to: &archive)
    }

    /// Emits a GNU `L` long-name member whose payload is the full path; the
    /// real header follows with a truncated name field that readers ignore.
    private static func appendLongNameExtension(name: String, to archive: inout Data) {
        var payload = Data(name.utf8)
        payload.append(0) // GNU stores the name as a NUL-terminated C string.
        let header = makeHeader(
            name: gnuLongNameMarker,
            size: payload.count,
            mode: 0o644,
            mtime: Date(timeIntervalSince1970: 0),
            typeFlag: UInt8(ascii: "L")
        )
        archive.append(header)
        archive.append(payload)
        appendPadding(for: payload.count, to: &archive)
    }

    private static func makeHeader(
        name: String,
        size: Int,
        mode: UInt16,
        mtime: Date,
        typeFlag: UInt8
    ) -> Data {
        var header = [UInt8](repeating: 0, count: blockSize)

        func write(_ string: String, at offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            for (i, byte) in bytes.enumerated() { header[offset + i] = byte }
        }

        // Name (100 bytes), truncated — long names are carried by the `L` member.
        let nameBytes = Array(name.utf8.prefix(nameFieldLength))
        for (i, byte) in nameBytes.enumerated() { header[i] = byte }

        // mode/uid/gid: 6 octal digits, NUL, space (8 bytes each).
        write(String(format: "%06o", mode & 0o7777), at: 100, length: 8)
        write("000000 ", at: 108, length: 8)
        write("000000 ", at: 116, length: 8)

        // size: 11 octal digits + space (12 bytes).
        write(String(format: "%011o", size), at: 124, length: 12)
        // mtime: 11 octal digits + space (12 bytes).
        let seconds = max(0, Int(mtime.timeIntervalSince1970))
        write(String(format: "%011o", seconds), at: 136, length: 12)

        header[156] = typeFlag

        // ustar magic "ustar\0" + version "00".
        write("ustar", at: 257, length: 6)
        header[263] = UInt8(ascii: "0")
        header[264] = UInt8(ascii: "0")

        // Checksum: fill field with spaces, sum every byte, then write octal.
        for i in 148..<156 { header[i] = UInt8(ascii: " ") }
        let checksum = header.reduce(0) { $0 + Int($1) }
        write(String(format: "%06o", checksum), at: 148, length: 7)
        header[154] = 0
        header[155] = UInt8(ascii: " ")

        return Data(header)
    }

    private static func appendPadding(for size: Int, to archive: inout Data) {
        let remainder = size % blockSize
        if remainder != 0 {
            archive.append(Data(repeating: 0, count: blockSize - remainder))
        }
    }
}
