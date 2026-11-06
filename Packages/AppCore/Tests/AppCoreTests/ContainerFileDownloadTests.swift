import Foundation
import Testing
@testable import AppCore
import DockerKit

@Suite struct ContainerFileDownloadTests {
    @Test func namesFilesAndFolders() {
        #expect(ContainerFileDownload.localName(for: "nginx.conf", isDirectory: false) == "nginx.conf")
        #expect(ContainerFileDownload.localName(for: "html", isDirectory: true) == "html.tar")
        #expect(ContainerFileDownload.localName(for: "/etc/hosts", isDirectory: false) == "hosts")
        #expect(ContainerFileDownload.localName(for: "", isDirectory: false) == "download")
    }

    @Test func unpacksASingleFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gantry-dl-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let archive = try TarWriter.archiveFileURL(file, recursive: false)
        let data = try ContainerFileDownload.contents(ofArchive: archive, name: "a.txt", isDirectory: false)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test func keepsAFolderArchive() throws {
        let archive = Data([1, 2, 3])
        #expect(try ContainerFileDownload.contents(ofArchive: archive, name: "dir", isDirectory: true) == archive)
    }

    @Test func refusesAnArchiveWithoutAFile() {
        #expect(throws: ContainerFileDownload.Failure.noFileInArchive("sock")) {
            try ContainerFileDownload.contents(ofArchive: Data(count: 1024), name: "sock", isDirectory: false)
        }
        #expect(throws: ContainerFileDownload.Failure.noFileInArchive("x")) {
            try ContainerFileDownload.contents(ofArchive: Data(), name: "x", isDirectory: false)
        }
    }

    @Test func findsUploadConflicts() {
        let conflicts = ContainerFileDownload.conflicts(uploading: ["a", "b", "c"], existing: ["b", "c", "d"])
        #expect(conflicts == ["b", "c"])
        #expect(ContainerFileDownload.conflicts(uploading: ["a"], existing: []).isEmpty)
    }
}
