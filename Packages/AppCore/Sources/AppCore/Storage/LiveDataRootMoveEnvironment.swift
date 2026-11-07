import Foundation
import DockerKit

/// The real side effects of a data root move: the `container` CLI, `cp`
/// and the file system.
public struct LiveDataRootMoveEnvironment: DataRootMoveEnvironment {
    public let cliOverride: String?
    public let store: AppleDataRootStore

    public init(cliOverride: String? = nil, store: AppleDataRootStore = .shared) {
        self.cliOverride = cliOverride
        self.store = store
    }

    public func listing() async throws -> StorageListing {
        async let containers = count(["list", "--all", "--format", "json"])
        async let images = count(["image", "list", "--format", "json"])
        async let volumes = count(["volume", "list", "--format", "json"])
        return try await StorageListing(containers: containers, images: images, volumes: volumes)
    }

    private func count(_ arguments: [String]) async throws -> Int {
        let text = try await AppleContainerControl.runContainer(arguments, cliOverride: cliOverride)
        return Self.countJSONArray(text)
    }

    /// The number of items in a JSON array printed by the CLI.
    static func countJSONArray(_ text: String) -> Int {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return array.count
    }

    public func stopServices() async throws {
        try await AppleContainerControl.stopServices(cliOverride: cliOverride)
    }

    public func startServices(_ root: AppleDataRoot) async throws {
        try await AppleContainerControl.startServices(cliOverride: cliOverride, dataRoot: root)
    }

    public func copyTree(
        from source: String,
        to destination: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let watcher = Task.detached {
            let sizing = FileSystemStorageSizing()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if let size = sizing.size(of: destination) { progress(size.allocated) }
            }
        }
        defer { watcher.cancel() }
        try await TreeCopy.copy(from: source, to: destination)
    }

    public func manifest(of path: String) async throws -> TreeManifest {
        try await Task.detached { try TreeManifest.read(path) }.value
    }

    public func removeTree(_ path: String) async throws {
        try await Task.detached {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }.value
    }

    public func saveRoot(_ root: AppleDataRoot) throws {
        try store.save(root)
    }
}

/// Copies a file tree with `/bin/cp -a`.
///
/// Tested on macOS 26: across disks `cp -a` keeps the holes of sparse disk
/// images and the xattrs; `ditto` fills the holes and `openrsync` drops the
/// xattrs. Sockets are skipped with a note and exit 0.
public enum TreeCopy {
    public static let executable = "/bin/cp"

    public static func arguments(from source: String, to destination: String) -> [String] {
        ["-a", StoragePaths.normalized(source), StoragePaths.normalized(destination)]
    }

    public static func copy(from source: String, to destination: String) async throws {
        let result = try await ChildProcess.run(executable, arguments(from: source, to: destination))
        guard result.exit.succeeded else {
            let message = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OperationFailure(message.isEmpty
                ? String(localized: "The copy failed.", bundle: .module)
                : message)
        }
    }
}
