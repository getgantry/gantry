import Foundation
import Observation
import DockerKit

/// The connected disks, for every host. The app updates it from the
/// NSWorkspace mount notifications.
@MainActor
@Observable
public final class StorageMonitor {
    public static let shared = StorageMonitor()

    public var presence: DiskPresence
    /// Folder volumes of all hosts.
    public let folderVolumes: FolderVolumeStore

    public init(presence: DiskPresence = .current(), folderVolumes: FolderVolumeStore = .shared) {
        self.presence = presence
        self.folderVolumes = folderVolumes
    }
}

extension HostSession {
    /// The `container` CLI path override of an apple host, or nil.
    var storageCLIOverride: String? {
        guard host.isAppleContainer else { return nil }
        let path = host.socketPathOverride?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Host paths are paths on this Mac: apple hosts and the local Docker
    /// host. Over SSH a path is on the other machine.
    public var usesLocalPaths: Bool { !host.isSSH }

    /// Missing disks that a container mounts from, or nil when all are here.
    public func storageBlock(for container: ContainerSummary, monitor: StorageMonitor = .shared) -> StorageBlock? {
        guard usesLocalPaths else { return nil }
        let disks = monitor.presence.missingDisks(
            for: container, folderVolumes: monitor.folderVolumes.paths(for: host.id)
        )
        return disks.isEmpty ? nil : StorageBlock(disks: disks)
    }

    /// For an apple host whose data root is on a missing disk.
    public func dataRootBlock(monitor: StorageMonitor = .shared, store: AppleDataRootStore = .shared) -> StorageBlock? {
        guard host.isAppleContainer else { return nil }
        let root = store.load().effectivePath
        return monitor.presence.missingDisk(for: root).map { StorageBlock(disks: [$0]) }
    }

    // MARK: - Helper containers

    /// Runs a helper job to the end. Throws with the job's output on failure.
    public func runHelperJob(_ job: HelperJob, purpose: String) async throws {
        let name = HelperJob.containerName(purpose)
        if host.isAppleContainer {
            _ = try await AppleContainerControl.runContainer(job.appleArguments(name: name), cliOverride: storageCLIOverride)
            return
        }
        guard let client else { throw DockerError.connectionFailed(String(localized: "Not connected", bundle: .module)) }
        let id: String
        do {
            id = try await client.createContainer(config: job.dockerRequest(name: name), name: name)
        } catch DockerError.apiError(status: 404, _) {
            for try await _ in try await pullImage(reference: job.image) {}
            id = try await client.createContainer(config: job.dockerRequest(name: name), name: name)
        }
        do {
            try await client.startContainer(id: id)
            let code = try await client.waitContainer(id: id)
            if code != 0 {
                let lines = (try? await recentLogLines(for: id, tail: 5)) ?? []
                throw OperationFailure(lines.isEmpty
                    ? String(localized: "The helper container exited with code \(code).", bundle: .module)
                    : lines.joined(separator: "\n"))
            }
        } catch {
            try? await client.removeContainer(id: id, force: true)
            throw error
        }
        try? await client.removeContainer(id: id, force: true)
    }

    // MARK: - Volumes

    /// Copies all files of a volume or folder to another volume or folder.
    public func copyVolumeData(from source: VolumeEndpoint, to destination: VolumeEndpoint) async throws {
        try await runHelperJob(VolumeTransferPlan.copy(from: source, to: destination), purpose: "copy")
    }

    /// Writes a volume to a tar archive in `folder`. Returns the file path.
    @discardableResult
    public func exportVolume(_ volume: VolumeEndpoint, name: String, toFolder folder: String) async throws -> String {
        let fileName = VolumeTransferPlan.archiveName(for: name)
        try await runHelperJob(VolumeTransferPlan.exportTar(volume, toFolder: folder, fileName: fileName), purpose: "export")
        return StoragePaths.normalized(folder) + "/" + fileName
    }

    /// Unpacks a tar archive into a volume.
    public func importVolume(file: String, into volume: VolumeEndpoint) async throws {
        try await runHelperJob(VolumeTransferPlan.importTar(file: file, into: volume), purpose: "import")
    }

    /// Makes a folder volume: a new folder `<parent>/<name>`. apple hosts
    /// record it in Gantry's store; Docker hosts get a `local` volume that
    /// binds the folder.
    public func createFolderVolume(
        name: String,
        parent: String,
        labels: [String: String] = [:],
        monitor: StorageMonitor = .shared,
        fileManager: FileManager = .default
    ) async throws {
        guard FolderVolumeRules.isValidName(name) else { throw FolderVolumeError.invalidName(name) }
        let taken = Set(volumes.map(\.name))
        if taken.contains(name) || monitor.folderVolumes.volume(named: name, hostID: host.id) != nil {
            throw FolderVolumeError.nameTaken(name)
        }
        let path = FolderVolumeRules.folder(named: name, in: parent)
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        if host.isAppleContainer {
            try monitor.folderVolumes.add(name: name, path: path, hostID: host.id, takenNames: taken)
            return
        }
        let created = await createVolume(
            name: name, driver: "local", labels: labels,
            driverOptions: FolderVolumeRules.dockerBindOptions(path: path)
        )
        if created == nil {
            throw OperationFailure(lastError ?? String(localized: "Could not create the volume.", bundle: .module))
        }
    }

    /// Makes `container` again with every mount of `old` changed to `new`.
    /// The container's own files (not in volumes) are lost, like `docker rm`.
    @discardableResult
    public func recreate(_ container: ContainerSummary, replacing old: VolumeEndpoint, with new: VolumeEndpoint) async throws -> String {
        guard let details = await details(for: container.id) else {
            throw OperationFailure(String(localized: "Could not read the container settings.", bundle: .module))
        }
        let binds = VolumeTransferPlan.replacingSource(in: details.hostConfig.binds ?? [], old: old, new: new)
        let request = recreationRequest(container: container, details: details, binds: binds)
        let wasRunning = container.state.isRunning
        _ = await perform(.remove(force: true), on: container.id)
        if wasRunning { return try await createAndRun(request) }
        return try await createContainer(request)
    }

    // MARK: - Images

    /// Saves images to a tar archive at `path`.
    public func saveImages(_ references: [String], to path: String) async throws {
        if host.isAppleContainer {
            _ = try await AppleContainerControl.runContainer(
                ImageArchive.appleSaveArguments(references: references, to: path), cliOverride: storageCLIOverride
            )
            return
        }
        guard let client else { throw DockerError.connectionFailed(String(localized: "Not connected", bundle: .module)) }
        let stream = try await client.saveImages(references: references)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw OperationFailure(String(localized: "Could not write \(path).", bundle: .module))
        }
        defer { try? handle.close() }
        do {
            for try await chunk in stream.bytes { try handle.write(contentsOf: chunk) }
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    /// Loads the images of a tar archive. Refreshes the image list.
    public func loadImages(from path: String) async throws {
        if host.isAppleContainer {
            _ = try await AppleContainerControl.runContainer(
                ImageArchive.appleLoadArguments(from: path), cliOverride: storageCLIOverride
            )
        } else {
            guard let client else { throw DockerError.connectionFailed(String(localized: "Not connected", bundle: .module)) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
            try await client.loadImages(archive: data)
        }
        await refreshImages()
    }
}
