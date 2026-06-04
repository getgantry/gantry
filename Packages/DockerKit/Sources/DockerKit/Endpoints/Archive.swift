import Foundation

extension DockerClient {
    /// `HEAD /containers/{id}/archive?path=` — stats a path inside a container.
    ///
    /// The metadata arrives in the base64-encoded JSON `X-Docker-Container-Path-Stat`
    /// response header.
    public func statPath(containerID: String, path: String) async throws -> ContainerPathStat {
        let response = try await requestData(
            method: .head,
            path: "/containers/\(containerID)/archive",
            query: [URLQueryItem(name: "path", value: path)],
            expecting: [200]
        )
        guard let value = Self.header(response.headers, "X-Docker-Container-Path-Stat") else {
            throw DockerError.decodingFailed("missing X-Docker-Container-Path-Stat header")
        }
        guard let json = Data(base64Encoded: value) else {
            throw DockerError.decodingFailed("invalid base64 in path-stat header")
        }
        return try decode(ContainerPathStat.self, from: json, path: "X-Docker-Container-Path-Stat")
    }

    /// `GET /containers/{id}/archive?path=` — downloads a path as a tar stream.
    public func downloadArchive(containerID: String, path: String) async throws -> DockerByteStream {
        let stream = try await byteStream(
            path: "/containers/\(containerID)/archive",
            query: [URLQueryItem(name: "path", value: path)]
        )
        guard stream.status == 200 else {
            throw DockerError.apiError(status: stream.status, message: "Failed to download archive")
        }
        return stream
    }

    /// `PUT /containers/{id}/archive?path=` — uploads a tar into a container path.
    public func uploadArchive(containerID: String, path: String, tar: Data) async throws {
        _ = try await requestData(
            method: .put,
            path: "/containers/\(containerID)/archive",
            query: [URLQueryItem(name: "path", value: path)],
            headers: ["Content-Type": "application/x-tar"],
            body: tar,
            expecting: [200]
        )
    }

    /// Upper bound on bytes buffered while listing a directory via the archive
    /// path. Beyond this the subtree is assumed too large to tar just to read
    /// one level, and the download is aborted.
    static let listArchiveByteCap = 64 * 1024 * 1024

    /// Lists the immediate contents of a directory inside a container.
    ///
    /// Downloads the directory archive, buffers it, and parses the tar headers
    /// client-side. Docker emits the directory's own entry as a prefix, which is
    /// dropped so only its children remain.
    ///
    /// This is the no-shell fallback for `listDirectoryFast`: it tars the entire
    /// subtree, so it is bounded at `listArchiveByteCap` and aborts (cancelling
    /// the stream) once the cap is exceeded without the archive completing,
    /// surfacing a clear error rather than transferring hundreds of MB.
    public func listDirectory(containerID: String, path: String) async throws -> [ContainerFileEntry] {
        let stream = try await downloadArchive(containerID: containerID, path: path)
        var buffer = Data()
        for try await chunk in stream.bytes {
            buffer.append(chunk)
            if buffer.count > Self.listArchiveByteCap {
                // Abort the transfer: dropping the iterator cancels the stream.
                throw DockerError.apiError(
                    status: 413,
                    message: "Directory too large to list without a shell in the container"
                )
            }
        }
        return Self.directoryEntries(fromArchive: buffer)
    }

    /// Parses a directory archive into immediate child entries.
    ///
    /// Docker prefixes every member with the requested directory's base name
    /// (e.g. `etc/`). Members one level below that prefix are returned; deeper
    /// members and the directory entry itself are skipped.
    static func directoryEntries(fromArchive data: Data) -> [ContainerFileEntry] {
        let members = TarReader.entries(in: data)
        var result: [ContainerFileEntry] = []

        for member in members {
            // Normalize: strip a trailing slash used to mark directories.
            let trimmed = member.name.hasSuffix("/") ? String(member.name.dropLast()) : member.name
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            // The root prefix is the first component; immediate children have
            // exactly two components (prefix + name).
            guard components.count == 2 else { continue }
            let name = String(components[1])
            result.append(
                ContainerFileEntry(
                    name: name,
                    isDirectory: member.isDirectory,
                    isSymlink: member.isSymlink,
                    size: member.size,
                    modified: member.mtime
                )
            )
        }
        return result
    }

    /// Case-insensitive HTTP header lookup over the response header map.
    private static func header(_ headers: [String: String], _ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        for (key, value) in headers where key.lowercased() == lowered {
            return value
        }
        return nil
    }
}
