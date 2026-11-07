import Foundation
import Testing
@testable import AppCore
@testable import DockerKit

// Live, on a real external disk. Gated:
//   GANTRY_STORAGE_LIVE_DIR=/Volumes/Disk/scratch swift test --filter LiveStorage
// The data root move runs on a small fake root with fake service calls, so
// the user's services never stop. Container tests use `gstore-` names.

private let liveDir = ProcessInfo.processInfo.environment["GANTRY_STORAGE_LIVE_DIR"] ?? ""
private let liveEnabled = liveDir.hasPrefix("/Volumes/")
private let appleEnabled = liveEnabled
    && ProcessInfo.processInfo.environment["GANTRY_STORAGE_LIVE_APPLE"] == "1"
    && AppleContainerCLIDiscovery.discover() != nil

/// Real copy, manifest and remove; services, listing and the store are fake.
private struct CopyOnlyEnvironment: DataRootMoveEnvironment {
    let live = LiveDataRootMoveEnvironment()
    func listing() async throws -> StorageListing { StorageListing(containers: 0, images: 0, volumes: 0) }
    func stopServices() async throws {}
    func startServices(_ root: AppleDataRoot) async throws {}
    func copyTree(from source: String, to destination: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await live.copyTree(from: source, to: destination, progress: progress)
    }
    func manifest(of path: String) async throws -> TreeManifest { try await live.manifest(of: path) }
    func removeTree(_ path: String) async throws { try await live.removeTree(path) }
    func saveRoot(_ root: AppleDataRoot) throws {}
}

private func allocated(_ path: String) -> Int64 {
    FileSystemStorageSizing().size(of: path)?.allocated ?? -1
}

@Suite(.serialized, .enabled(if: liveEnabled))
struct LiveStorageTests {
    @Test func readsTheExternalDisk() throws {
        let disk = try #require(SystemStorageDiskReader().disk(containing: liveDir))
        #expect(disk.mountPath.hasPrefix("/Volumes/"))
        #expect(disk.placement != .internal)
        #expect(disk.totalBytes > 0 && disk.availableBytes > 0)
        #expect(SystemStorageDiskReader().disk(containing: "/Volumes/gstore-not-here/x") == nil)
        #expect(DiskPresence.current().isConnected(liveDir))
        #expect(!DiskPresence.current().isConnected("/Volumes/gstore-not-here/x"))
    }

    @Test(.timeLimit(.minutes(2)))
    func movesAFakeRootThereAndBackAndKeepsSparseFiles() async throws {
        let fm = FileManager.default
        let id = UUID().uuidString.prefix(8)
        let internalRoot = fm.temporaryDirectory.appendingPathComponent("gstore-root-\(id)").path
        let externalRoot = liveDir + "/gstore-root-\(id)"
        defer {
            try? fm.removeItem(atPath: internalRoot)
            try? fm.removeItem(atPath: externalRoot)
        }
        try fm.createDirectory(atPath: internalRoot + "/volumes/db", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: internalRoot + "/kernels", withIntermediateDirectories: true)
        let image = internalRoot + "/volumes/db/volume.img"
        fm.createFile(atPath: image, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: image))
        try handle.write(contentsOf: Data(repeating: 7, count: 1 << 20))
        try handle.truncate(atOffset: 512 << 20)
        try handle.close()
        try fm.createSymbolicLink(atPath: internalRoot + "/kernels/default", withDestinationPath: "vmlinux")
        _ = setxattr(image, "com.gantry.test", "x", 1, 0, 0)
        #expect(allocated(image) < 8 << 20)

        let disk = try #require(SystemStorageDiskReader().disk(containing: liveDir))
        let size = try #require(FileSystemStorageSizing().size(of: internalRoot))
        let plan = try DataRootMovePlan.make(
            source: internalRoot, size: size, disk: disk, destination: externalRoot,
            isEmptyOrMissing: StorageOverview.isEmptyOrMissing
        ).get()
        let mover = DataRootMover(environment: CopyOnlyEnvironment())
        try await mover.run(plan, totalBytes: size.allocated) { _ in }

        let copied = externalRoot + "/volumes/db/volume.img"
        #expect(allocated(copied) < 8 << 20, "the copy must stay sparse")
        #expect((try fm.attributesOfItem(atPath: copied)[.size] as? Int64) == 512 << 20)
        #expect(getxattr(copied, "com.gantry.test", nil, 0, 0, 0) == 1)
        #expect(try fm.destinationOfSymbolicLink(atPath: externalRoot + "/kernels/default") == "vmlinux")

        // And back to a new internal folder; the old copy is deleted only after.
        try await mover.environment.removeTree(internalRoot)
        let back = try DataRootMovePlan.make(
            source: externalRoot, size: size, disk: try #require(SystemStorageDiskReader().disk(containing: internalRoot)),
            destination: internalRoot, isEmptyOrMissing: StorageOverview.isEmptyOrMissing
        ).get()
        try await mover.run(back, totalBytes: size.allocated) { _ in }
        #expect(allocated(image) < 8 << 20)
        try await mover.deleteOldRoot(externalRoot, activeRoot: internalRoot)
        #expect(!fm.fileExists(atPath: externalRoot))
    }
}

@Suite(.serialized, .enabled(if: appleEnabled))
@MainActor
struct LiveAppleStorageTests {
    @Test(.timeLimit(.minutes(5)))
    func folderVolumeCopyExportImportAndRecreate() async throws {
        let session = HostSession(host: DockerHost(name: "gstore", kind: .appleContainer))
        await session.connect()
        #expect(session.status.isConnected)
        let fm = FileManager.default
        let id = UUID().uuidString.prefix(6).lowercased()
        let named = "gstore-vol-\(id)", restored = "gstore-back-\(id)", folderName = "gstore-folder-\(id)"
        let parent = liveDir + "/gstore-\(id)"
        let store = FolderVolumeStore(fileURL: nil)
        let monitor = StorageMonitor(presence: .current(), folderVolumes: store)
        defer {
            try? fm.removeItem(atPath: parent)
        }

        #expect(await session.createVolume(name: named) != nil)
        try await session.runHelperJob(HelperJob(
            mounts: [.init(source: named, target: "/to", readOnly: false)],
            script: "echo hello > /to/a.txt && mkdir -p /to/sub && echo x > /to/sub/b"
        ), purpose: "seed")

        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try await session.createFolderVolume(name: folderName, parent: parent, monitor: monitor)
        let folder = parent + "/" + folderName
        #expect(store.volume(named: folderName, hostID: session.host.id)?.path == folder)
        try await session.copyVolumeData(from: .named(named), to: .folder(folder))
        #expect((try? String(contentsOfFile: folder + "/a.txt", encoding: .utf8)) == "hello\n")
        #expect(fm.fileExists(atPath: folder + "/sub/b"))

        let archive = try await session.exportVolume(.folder(folder), name: folderName, toFolder: parent)
        #expect(fm.fileExists(atPath: archive))
        #expect(await session.createVolume(name: restored) != nil)
        try await session.importVolume(file: archive, into: .named(restored))
        try await session.runHelperJob(HelperJob(
            mounts: [.init(source: restored, target: "/to", readOnly: true)],
            script: "test \"$(cat /to/a.txt)\" = hello && test -f /to/sub/b"
        ), purpose: "check")

        _ = await session.removeVolume(name: named, force: true)
        _ = await session.removeVolume(name: restored, force: true)
    }

    @Test(.timeLimit(.minutes(3)))
    func savesAndLoadsAnImage() async throws {
        let session = HostSession(host: DockerHost(name: "gstore", kind: .appleContainer))
        await session.connect()
        let file = liveDir + "/gstore-image-\(UUID().uuidString.prefix(6)).tar"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try await session.saveImages([HelperJob.defaultImage], to: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int64) ?? 0
        #expect(size > 1_000_000)
        try await session.loadImages(from: file)
    }
}
