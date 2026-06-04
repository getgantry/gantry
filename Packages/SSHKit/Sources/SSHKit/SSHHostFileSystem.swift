import Foundation
import Citadel
import NIOCore

/// One entry of a host directory listing (over SFTP).
public struct HostFileEntry: Sendable, Hashable, Identifiable {
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool

    public var id: String { name }
}

/// Browses the SSH host's filesystem over SFTP.
///
/// Owns a dedicated SSH connection, built lazily on first use and reusable
/// across calls; `close()` releases it. All requests are serialized by the
/// actor, which matches SFTP's request/response model.
public actor SSHHostFileSystem {
    public typealias MakeClient = @Sendable () async throws -> SSHClient

    private let makeClient: MakeClient
    private var client: SSHClientBox?
    private var sftp: SFTPClient?

    public init(makeClient: @escaping MakeClient) {
        self.makeClient = makeClient
    }

    private func ensureSFTP() async throws -> SFTPClient {
        if let sftp, sftp.isActive { return sftp }
        // A dead SFTP channel means the connection is gone; rebuild both.
        if let client {
            await client.close()
            self.client = nil
            self.sftp = nil
        }
        let box = SSHClientBox(client: try await makeClient())
        do {
            let sftp = try await box.client.openSFTP()
            self.client = box
            self.sftp = sftp
            return sftp
        } catch {
            await box.close()
            throw error
        }
    }

    /// Lists a directory, directories first, dotfiles included, "." and ".."
    /// dropped.
    public func listDirectory(_ path: String) async throws -> [HostFileEntry] {
        let names = try await ensureSFTP().listDirectory(atPath: path)
        var entries: [HostFileEntry] = []
        for component in names.flatMap(\.components) {
            let name = component.filename
            if name == "." || name == ".." { continue }
            // The longname is the server's `ls -l` line; its first character
            // is the canonical type flag.
            let kind = component.longname.first
            entries.append(
                HostFileEntry(
                    name: name,
                    size: Int64(component.attributes.size ?? 0),
                    isDirectory: kind == "d",
                    isSymlink: kind == "l"
                )
            )
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Streams a remote file's bytes into `chunk`, 128 KB at a time.
    public func downloadFile(_ path: String, chunk: @Sendable (Data) async throws -> Void) async throws {
        let file = try await ensureSFTP().openFile(filePath: path, flags: .read)
        do {
            var offset: UInt64 = 0
            while true {
                let buffer = try await file.read(from: offset, length: 1 << 17)
                if buffer.readableBytes == 0 { break }
                offset += UInt64(buffer.readableBytes)
                try await chunk(Data(buffer: buffer))
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// Releases the SFTP channel and its SSH connection.
    public func close() async {
        if let sftp {
            try? await sftp.close()
        }
        sftp = nil
        if let client {
            await client.close()
        }
        client = nil
    }
}
