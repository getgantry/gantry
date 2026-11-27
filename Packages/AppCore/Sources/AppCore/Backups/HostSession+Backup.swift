import Foundation
import DockerKit

extension HostSession {
    /// How long a backup waits for a host that is still connecting.
    static let backupConnectTimeout: Duration = .seconds(60)

    /// Writes the volume `name` as a tar archive to `<folder>/<fileName>` on
    /// this Mac. Apple hosts run the export helper job of spec 004; Docker
    /// hosts stream the archive of an unstarted helper, which also works over SSH.
    public func backUpVolume(
        _ name: String,
        toFolder folder: String,
        fileName: String,
        disks: any StorageDiskReading = SystemStorageDiskReader()
    ) async throws {
        try await waitForBackupConnection()
        await refreshVolumes()
        guard volumes.contains(where: { $0.name == name }) else { throw BackupFailure.volumeNotFound(name) }
        await refreshVolumeSizes(force: false)
        if let needed = volumeSizes[name],
           let issue = VolumeTransferPlan.spaceIssue(needed: needed, on: disks.disk(containing: folder)) {
            throw OperationFailure(issue.message)
        }
        let path = StoragePaths.normalized(folder) + "/" + fileName
        if host.isAppleContainer {
            try await runHelperJob(
                VolumeTransferPlan.exportTar(.named(name), toFolder: folder, fileName: fileName), purpose: "backup"
            )
            return
        }
        try await streamDockerBackup(volume: name, to: path)
    }

    /// Connects a disconnected host, or waits for one that is connecting.
    func waitForBackupConnection(clock: ContinuousClock = ContinuousClock()) async throws {
        if case .disconnected = status { await connect() }
        if case .failed = status { await connect() }
        let deadline = clock.now.advanced(by: Self.backupConnectTimeout)
        while case .connecting = status, clock.now < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        guard status.isConnected else { throw BackupFailure.hostOffline(host.name) }
    }

    /// The helper job of a Docker backup: the volume read-only at `/from`.
    static func dockerBackupJob(volume: String) -> HelperJob {
        HelperJob(mounts: [.init(source: volume, target: "/from", readOnly: true)], script: "true")
    }

    /// `GET /containers/{id}/archive?path=/from/.` gives entries `./…`, the
    /// same layout as `tar -C /from .`, so Import from Archive reads it.
    private func streamDockerBackup(volume: String, to path: String) async throws {
        let name = HelperJob.containerName("backup")
        let (client, id) = try await createDockerHelper(Self.dockerBackupJob(volume: volume), name: name)
        defer { Task { try? await client.removeContainer(id: id, force: true) } }
        let stream = try await client.downloadArchive(containerID: id, path: "/from/.")
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw OperationFailure(String(localized: "Could not write \(path).", bundle: .module))
        }
        defer { try? handle.close() }
        for try await chunk in stream.bytes { try handle.write(contentsOf: chunk) }
    }
}
