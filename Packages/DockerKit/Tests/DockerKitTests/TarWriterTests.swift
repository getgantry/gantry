import Foundation
import Testing
@testable import DockerKit

/// Round-trips ``TarWriter`` output through ``TarReader`` to verify the writer
/// produces archives the app's own parser accepts.
struct TarWriterTests {
    @Test func roundTripsNestedDirectoriesAndFiles() throws {
        let helloData = Data("hello world".utf8)
        let entries: [TarEntry] = [
            TarEntry(name: "top", isDirectory: true, mode: 0o755),
            TarEntry(name: "top/file.txt", data: helloData, mode: 0o644),
            TarEntry(name: "top/sub", isDirectory: true, mode: 0o755),
            TarEntry(name: "top/sub/inner.bin", data: Data([0, 1, 2, 3, 255]), mode: 0o600)
        ]

        let archive = TarWriter.archive(entries: entries)
        let parsed = TarReader.entries(in: archive)

        #expect(parsed.count == 4)

        let topDir = try #require(parsed.first { $0.name == "top/" })
        #expect(topDir.isDirectory)

        let subDir = try #require(parsed.first { $0.name == "top/sub/" })
        #expect(subDir.isDirectory)

        let file = try #require(parsed.first { $0.name == "top/file.txt" })
        #expect(!file.isDirectory)
        #expect(file.size == Int64(helloData.count))

        let bin = try #require(parsed.first { $0.name == "top/sub/inner.bin" })
        #expect(bin.size == 5)
    }

    @Test func roundTripsLongNamesViaGNUExtension() throws {
        // 100+ char path forces the GNU "L" long-name extension.
        let longComponent = String(repeating: "a", count: 80)
        let longName = "deeply/nested/\(longComponent)/\(longComponent).txt"
        #expect(longName.utf8.count > 100)

        let payload = Data("x".utf8)
        let archive = TarWriter.archive(entries: [
            TarEntry(name: longName, data: payload)
        ])
        let parsed = TarReader.entries(in: archive)

        // Only the real member should surface; the "L" header is consumed.
        #expect(parsed.count == 1)
        #expect(parsed[0].name == longName)
        #expect(parsed[0].size == 1)
    }

    @Test func preservesBinaryPayloadContents() throws {
        // Build a payload that is not a multiple of 512 to exercise padding.
        var binary = Data()
        for i in 0..<1000 { binary.append(UInt8(i % 256)) }

        let archive = TarWriter.singleFile(name: "blob", contents: binary)
        let parsed = TarReader.entries(in: archive)
        #expect(parsed.count == 1)
        #expect(parsed[0].size == 1000)

        // Re-extract the payload from the raw archive and compare bytes.
        let extracted = archive.subdata(in: 512 ..< 512 + 1000)
        #expect(extracted == binary)
    }

    @Test func archivesFileURLFromDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("note.txt")
        try Data("disk contents".utf8).write(to: fileURL)

        let archive = try TarWriter.archiveFileURL(fileURL, recursive: false)
        let parsed = TarReader.entries(in: archive)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "note.txt")
        #expect(parsed[0].size == Int64("disk contents".utf8.count))
    }

    @Test func archivesDirectoryTreeFromDisk() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("nested")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let archive = try TarWriter.archiveFileURL(root, recursive: true)
        let parsed = TarReader.entries(in: archive)
        let names = Set(parsed.map(\.name))

        let rootName = root.lastPathComponent
        #expect(names.contains("\(rootName)/"))
        #expect(names.contains("\(rootName)/a.txt"))
        #expect(names.contains("\(rootName)/nested/"))
        #expect(names.contains("\(rootName)/nested/b.txt"))
    }

    @Test func endsWithTwoZeroBlocks() {
        let archive = TarWriter.singleFile(name: "x", contents: Data("y".utf8))
        let tail = archive.suffix(1024)
        #expect(tail.count == 1024)
        #expect(tail.allSatisfy { $0 == 0 })
    }
}
