import Foundation
import DockerKit

/// How a downloaded container path becomes a local file: a file is unpacked
/// from the archive the engine returns, a folder stays a `.tar`.
public enum ContainerFileDownload {
    public enum Failure: LocalizedError, Equatable {
        /// The archive held no regular file (a socket, a device, a broken
        /// symlink, or a truncated transfer).
        case noFileInArchive(String)

        public var errorDescription: String? {
            switch self {
            case .noFileInArchive(let name):
                String(localized: "“\(name)” could not be read as a regular file, so nothing was saved.", bundle: .module)
            }
        }
    }

    /// The name for the save panel and for a dragged-out file.
    public static func localName(for name: String, isDirectory: Bool) -> String {
        let base = (name as NSString).lastPathComponent
        let safe = base.isEmpty || base == "/" ? "download" : base
        return isDirectory ? safe + ".tar" : safe
    }

    /// The bytes to write locally for one downloaded archive.
    public static func contents(ofArchive archive: Data, name: String, isDirectory: Bool) throws -> Data {
        if isDirectory { return archive }
        guard let payload = TarReader.firstFilePayload(in: archive) else {
            throw Failure.noFileInArchive(name)
        }
        return payload
    }

    /// The names among `uploads` that already exist in the destination, so
    /// the user can confirm before they are replaced.
    public static func conflicts(uploading uploads: [String], existing: [String]) -> [String] {
        let present = Set(existing)
        return uploads.filter { present.contains($0) }
    }
}
