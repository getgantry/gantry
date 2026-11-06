import Foundation
import Testing
@testable import DockerKit

/// macOS tar writes extended attributes as AppleDouble `._name` entries;
/// the archive download must hold only the real file.
@Test func tarStreamHasNoAppleDoubleEntries() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("gantry-tar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let payload = Data("hello from gantry\n".utf8)
    let file = folder.appendingPathComponent("note.txt")
    try payload.write(to: file)
    // An extended attribute is what makes macOS tar add `._note.txt`.
    let status = setxattr(file.path, "com.apple.provenance", "x", 1, 0, 0)
    #expect(status == 0)

    var tar = Data()
    for try await chunk in AppleContainerTransport.tarStream(of: "note.txt", in: folder) {
        tar.append(chunk)
    }
    #expect(TarReader.entries(in: tar).map(\.name) == ["note.txt"])
    #expect(TarReader.firstFilePayload(in: tar) == payload)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}
