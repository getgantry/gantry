import Foundation

/// Backups on the hosts of the app, with the disk checks of spec 004.
@MainActor
public final class LiveBackupEnvironment: BackupEnvironment {
    weak var model: AppModel?
    let disks: any StorageDiskReading

    public init(model: AppModel, disks: any StorageDiskReading = SystemStorageDiskReader()) {
        self.model = model
        self.disks = disks
    }

    public func folderProblem(_ folder: String) async -> String? {
        if let disk = DiskPresence.current().missingDisk(for: folder) {
            return StorageIssue.missing(disk).message
        }
        if case .waitingForPermission(diskName: let name) = await DiskAccessGate.shared.check(folder) {
            return StorageIssue.waitingForPermission(name).message
        }
        let exists = await Task.detached { () -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue
        }.value
        if !exists { return BackupFailure.folderNotFound(folder).errorDescription }
        let disk = await Task.detached { [disks] in disks.disk(containing: folder) }.value
        if disk?.isReadOnly == true { return StorageIssue.readOnly.message }
        return nil
    }

    public func export(_ schedule: BackupSchedule, fileName: String) async throws {
        guard let session = model?.session(id: schedule.hostID) else { throw BackupFailure.hostNotFound }
        try await session.backUpVolume(schedule.volume, toFolder: schedule.folder, fileName: fileName, disks: disks)
    }

    public func listFiles(in folder: String) async throws -> [String] {
        try await Task.detached { try FileManager.default.contentsOfDirectory(atPath: folder) }.value
    }

    public func fileHeader(_ path: String) async throws -> (size: Int64, header: Data) {
        try await Task.detached { () -> (size: Int64, header: Data) in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            return (size, try handle.read(upToCount: 512) ?? Data())
        }.value
    }

    public func moveFile(_ from: String, to: String) async throws {
        try await Task.detached { try FileManager.default.moveItem(atPath: from, toPath: to) }.value
    }

    public func removeFile(_ path: String) async throws {
        try await Task.detached { try FileManager.default.removeItem(atPath: path) }.value
    }
}
