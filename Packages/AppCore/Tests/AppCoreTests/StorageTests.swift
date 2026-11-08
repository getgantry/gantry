import Foundation
import Testing
import DockerKit
@testable import AppCore

// MARK: - Fixtures

private func disk(
    _ mount: String,
    fs: String = "apfs",
    placement: StoragePlacement = .external,
    total: Int64 = 1_000_000_000_000,
    free: Int64 = 500_000_000_000,
    readOnly: Bool = false,
    noOwners: Bool = false,
    boot: Bool = false
) -> StorageDisk {
    StorageDisk(
        mountPath: mount, name: (mount as NSString).lastPathComponent, fileSystemName: fs,
        totalBytes: total, availableBytes: free, placement: placement,
        isReadOnly: readOnly, ignoresOwnership: noOwners, isBootDisk: boot
    )
}

private func container(id: String, running: Bool, mounts: [(source: String, name: String?)]) throws -> ContainerSummary {
    let mountObjects: [[String: Any]] = mounts.map { mount in
        var object: [String: Any] = ["Source": mount.source, "Destination": "/data"]
        if let name = mount.name { object["Name"] = name; object["Type"] = "volume" } else { object["Type"] = "bind" }
        return object
    }
    let object: [String: Any] = [
        "Id": id, "Names": ["/\(id)"], "Image": "alpine", "ImageID": "sha256:1", "Command": "sh",
        "Created": 0, "Ports": [], "Labels": [:], "State": running ? "running" : "exited",
        "Status": "", "Mounts": mountObjects
    ]
    return try JSONDecoder().decode(ContainerSummary.self, from: JSONSerialization.data(withJSONObject: object))
}

// MARK: - Disks and checks

struct StorageDiskTests {
    @Test func mapsFileSystemNames() {
        #expect(StorageFileSystem(typeName: "apfs") == .apfs)
        #expect(StorageFileSystem(typeName: "hfs") == .hfs)
        #expect(StorageFileSystem(typeName: "exfat") == .exfat)
        #expect(StorageFileSystem(typeName: "msdos") == .fat)
        #expect(StorageFileSystem(typeName: "ntfs") == .ntfs)
        #expect(StorageFileSystem(typeName: "smbfs") == .network)
        #expect(StorageFileSystem(typeName: "zfs") == .other)
        #expect(StorageFileSystem.apfs.keepsUnixMetadata && StorageFileSystem.hfs.keepsUnixMetadata)
        #expect(!StorageFileSystem.exfat.keepsUnixMetadata)
    }

    @Test func pathsUnderVolumes() {
        #expect(StoragePaths.volumeMountPoint(of: "/Volumes/Fast/data/x") == "/Volumes/Fast")
        #expect(StoragePaths.volumeMountPoint(of: "/Volumes/Fast") == "/Volumes/Fast")
        #expect(StoragePaths.volumeMountPoint(of: "/Users/me/data") == nil)
        #expect(StoragePaths.volumeMountPoint(of: "/Volumes") == nil)
        #expect(StoragePaths.volumeName(of: "/Volumes/My Disk/a/") == "My Disk")
        #expect(StoragePaths.isInside("/Volumes/A/b", "/Volumes/A"))
        #expect(!StoragePaths.isInside("/Volumes/AB", "/Volumes/A"))
        #expect(StoragePaths.isInside("/x", "/"))
    }

    @Test func picksTheDiskWithTheLongestMountPoint() {
        let disks = [disk("/", placement: .internal, boot: true), disk("/Volumes/Fast")]
        #expect(StoragePaths.disk(containing: "/Volumes/Fast/a", in: disks)?.mountPath == "/Volumes/Fast")
        #expect(StoragePaths.disk(containing: "/Users/me", in: disks)?.mountPath == "/")
    }
}

struct StorageCheckTests {
    @Test func refusesFileSystemsWithoutUnixMetadata() {
        for fs in ["exfat", "msdos", "ntfs"] {
            let check = StorageCheck.dataRoot(on: disk("/Volumes/Stick", fs: fs), requiredBytes: 1)
            #expect(!check.isAllowed)
            #expect(check.blocking.contains { if case .unsupportedFileSystem = $0 { true } else { false } })
        }
    }

    @Test func allowsAPFSAndHFSWithARemovableWarning() {
        for fs in ["apfs", "hfs"] {
            let check = StorageCheck.dataRoot(on: disk("/Volumes/Fast", fs: fs), requiredBytes: 1)
            #expect(check.isAllowed)
            #expect(check.warnings == [.removable])
        }
    }

    @Test func warnsOnNetworkDisks() {
        let check = StorageCheck.dataRoot(on: disk("/Volumes/NAS", fs: "smbfs", placement: .network), requiredBytes: 1)
        #expect(check.isAllowed)
        #expect(check.warnings.contains(.networkDisk))
    }

    @Test func refusesTooLittleSpaceAndReadOnly() {
        let small = StorageCheck.dataRoot(on: disk("/Volumes/Fast", free: 10), requiredBytes: 11)
        #expect(small.blocking == [.notEnoughSpace(needed: 11, available: 10)])
        let readOnly = StorageCheck.dataRoot(on: disk("/Volumes/Fast", readOnly: true), requiredBytes: 1)
        #expect(readOnly.blocking == [.readOnly])
    }

    @Test func bindMountWarnings() {
        #expect(StorageCheck.bindMount(on: disk("/", placement: .internal, boot: true), path: "/Users/me").issues.isEmpty)
        #expect(StorageCheck.bindMount(on: nil, path: "/Volumes/Gone/x").issues == [.missing("Gone")])
        let stick = StorageCheck.bindMount(on: disk("/Volumes/Stick", fs: "exfat", placement: .removable), path: "/Volumes/Stick/a")
        #expect(stick.issues == [.removable, .ignoresOwnership])
        #expect(stick.isAllowed)
        let noOwners = StorageCheck.bindMount(on: disk("/Volumes/Fast", noOwners: true), path: "/Volumes/Fast/a")
        #expect(noOwners.issues == [.removable, .ignoresOwnership])
        let folder = StorageCheck.folderVolume(on: disk("/Volumes/Fast", readOnly: true), path: "/Volumes/Fast/a")
        #expect(!folder.isAllowed)
    }

    @Test func everyIssueHasAMessage() {
        let issues: [StorageIssue] = [
            .unsupportedFileSystem("ExFAT"), .networkDisk, .readOnly, .removable, .ignoresOwnership,
            .notEnoughSpace(needed: 2, available: 1), .missing("Disk")
        ]
        for issue in issues { #expect(!issue.message.isEmpty) }
    }
}

// MARK: - Usage

private struct FakeSizing: StorageSizing {
    var sizes: [String: StorageSize]
    var folders: [String: [String]]

    func size(of path: String) -> StorageSize? { sizes[path] }
    func children(of path: String) -> [String] { folders[path] ?? [] }
}

struct StorageUsageTests {
    @Test func sumsCategoriesOtherAndVolumes() {
        let root = "/R"
        let sizing = FakeSizing(
            sizes: [
                "/R/content": .init(allocated: 100, apparent: 100),
                "/R/containers": .init(allocated: 50, apparent: 900),
                "/R/snapshots": .init(allocated: 20, apparent: 20),
                "/R/volumes": .init(allocated: 8, apparent: 1000),
                "/R/apiserver": .init(allocated: 1, apparent: 1),
                "/R/state.json": .init(allocated: 2, apparent: 2),
                "/R/volumes/b": .init(allocated: 5, apparent: 500),
                "/R/volumes/a": .init(allocated: 3, apparent: 500)
            ],
            folders: [
                "/R": ["content", "containers", "snapshots", "volumes", "apiserver", "state.json"],
                "/R/volumes": ["b", "a"]
            ]
        )
        let usage = StorageUsageScanner.scan(root: root + "/", sizing: sizing)
        #expect(usage.root == "/R")
        #expect(usage.size(of: .images).allocated == 100)
        #expect(usage.size(of: .containers).apparent == 900)
        #expect(usage.size(of: .kernels) == StorageSize())
        #expect(usage.size(of: .other).allocated == 3)
        #expect(usage.total.allocated == 181)
        #expect(usage.volumes.map(\.name) == ["a", "b"])
        #expect(usage.volumes.first?.size == StorageSize(allocated: 3, apparent: 500))
    }
}

// MARK: - Data root move

struct DataRootMovePlanTests {
    private let size = StorageSize(allocated: 6_000_000_000, apparent: 20_000_000_000)

    @Test func plansAMoveToAnAPFSDisk() throws {
        let plan = try DataRootMovePlan.make(
            source: "/Users/me/Library/Application Support/com.apple.container/",
            size: size, disk: disk("/Volumes/Fast"), isEmptyOrMissing: { _ in true }
        ).get()
        #expect(plan.destination == "/Volumes/Fast/com.apple.container")
        #expect(plan.source == "/Users/me/Library/Application Support/com.apple.container")
        #expect(plan.requiredBytes == size.allocated + DataRootMovePlan.marginBytes)
        #expect(plan.warnings == [.removable])
    }

    @Test func movesBackToTheDefaultFolderOnTheBootDisk() {
        let boot = disk("/", placement: .internal, boot: true)
        #expect(DataRootMovePlan.destination(on: boot) == AppleDataRoot.defaultPath)
    }

    @Test func refusesBadTargets() {
        let fast = disk("/Volumes/Fast")
        #expect(DataRootMovePlan.make(source: "/Volumes/Fast/com.apple.container", size: size, disk: fast, isEmptyOrMissing: { _ in true })
            == .failure(.sameLocation))
        #expect(DataRootMovePlan.make(source: "/Volumes/Fast", size: size, disk: fast, isEmptyOrMissing: { _ in true })
            == .failure(.destinationInsideSource))
        #expect(DataRootMovePlan.make(source: "/R", size: size, disk: fast, isEmptyOrMissing: { _ in false })
            == .failure(.destinationNotEmpty("/Volumes/Fast/com.apple.container")))
        if case .failure(.diskRefused(let issues)) = DataRootMovePlan.make(
            source: "/R", size: size, disk: disk("/Volumes/Stick", fs: "exfat"), isEmptyOrMissing: { _ in true }
        ) {
            #expect(issues.count == 1)
        } else {
            Issue.record("exFAT must be refused")
        }
        if case .failure(.diskRefused(let issues)) = DataRootMovePlan.make(
            source: "/R", size: size, disk: disk("/Volumes/Fast", free: 1_000), isEmptyOrMissing: { _ in true }
        ) {
            #expect(issues == [.notEnoughSpace(needed: size.allocated + DataRootMovePlan.marginBytes, available: 1_000)])
        } else {
            Issue.record("too little space must be refused")
        }
    }
}

/// Records the calls of a move; each step can fail on request.
private final class FakeMoveEnvironment: DataRootMoveEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _saved: [AppleDataRoot] = []
    private var listings: [StorageListing]
    private let copyManifest: TreeManifest
    private let failStartOn: String?
    /// Cancels the running move from inside the copy, like a click on Cancel.
    var cancelDuringCopy = false

    let original = TreeManifest(entries: [
        "volumes": .init(kind: .directory),
        "volumes/a/volume.img": .init(kind: .file, size: 1 << 30),
        "kernels/default": .init(kind: .symlink, linkTarget: "vmlinux-6.1")
    ])

    init(listings: [StorageListing], copyMatches: Bool = true, failStartOn: String? = nil) {
        self.listings = listings
        self.failStartOn = failStartOn
        var copy = original
        if !copyMatches { copy.entries["volumes/a/volume.img"]?.size = 10 }
        self.copyManifest = copy
    }

    var calls: [String] { lock.withLock { _calls } }
    var savedRoots: [AppleDataRoot] { lock.withLock { _saved } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func listing() async throws -> StorageListing {
        lock.withLock {
            _calls.append("listing")
            return listings.count > 1 ? listings.removeFirst() : listings[0]
        }
    }

    func stopServices() async throws { record("stop") }

    func startServices(_ root: AppleDataRoot) async throws {
        record("start \(root.path ?? "default")")
        if let failStartOn, root.path == failStartOn { throw OperationFailure("no start") }
    }

    func copyTree(from source: String, to destination: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        record("copy \(source) -> \(destination)")
        progress(42)
        if cancelDuringCopy { withUnsafeCurrentTask { $0?.cancel() } }
        try Task.checkCancellation()
    }

    func manifest(of path: String) async throws -> TreeManifest {
        record("manifest \(path)")
        return path == "/R" ? original : copyManifest
    }

    func removeTree(_ path: String) async throws { record("remove \(path)") }

    func saveRoot(_ root: AppleDataRoot) throws {
        lock.withLock {
            _saved.append(root)
            _calls.append("save \(root.path ?? "default")")
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DataRootMoveProgress] = []
    func add(_ item: DataRootMoveProgress) { lock.withLock { items.append(item) } }
    var steps: [DataRootMoveStep] { lock.withLock { items.map(\.step) } }
    var fractions: [Double] { lock.withLock { items.compactMap(\.fraction) } }
}

struct DataRootMoverTests {
    private let plan = DataRootMovePlan(source: "/R", destination: "/Volumes/Fast/com.apple.container", requiredBytes: 0, warnings: [])
    private let same = StorageListing(containers: 2, images: 3, volumes: 1)

    @Test func movesInOrderAndReturnsTheOldRoot() async throws {
        let env = FakeMoveEnvironment(listings: [same, same])
        let log = ProgressLog()
        let old = try await DataRootMover(environment: env).run(plan, totalBytes: 84) { log.add($0) }
        #expect(old == "/R")
        let calls = env.calls
        #expect(calls == [
            "listing", "stop", "copy /R -> /Volumes/Fast/com.apple.container",
            "manifest /R", "manifest /Volumes/Fast/com.apple.container",
            "save /Volumes/Fast/com.apple.container", "start /Volumes/Fast/com.apple.container", "listing"
        ])
        #expect(log.steps.first == .listBefore && log.steps.last == .checkListing)
        #expect(log.fractions.contains(0.5))
        #expect(!calls.contains { $0.hasPrefix("remove") })
    }

    @Test func aBadCopyKeepsTheOriginal() async throws {
        let env = FakeMoveEnvironment(listings: [same], copyMatches: false)
        await #expect(throws: DataRootMoveError.self) {
            try await DataRootMover(environment: env).run(plan, totalBytes: 1) { _ in }
        }
        let calls = env.calls
        #expect(!calls.contains { $0.hasPrefix("save") })
        #expect(calls.suffix(2) == ["remove /Volumes/Fast/com.apple.container", "start /R"])
    }

    @Test func cancelDuringCopyRestoresTheOldRoot() async throws {
        let env = FakeMoveEnvironment(listings: [same])
        env.cancelDuringCopy = true
        let task = Task { try await DataRootMover(environment: env).run(plan, totalBytes: 1) { _ in } }
        await #expect(throws: CancellationError.self) { try await task.value }
        let calls = env.calls
        #expect(!calls.contains { $0.hasPrefix("save") })
        #expect(!calls.contains { $0.hasPrefix("manifest") })
        #expect(calls.suffix(2) == ["remove /Volumes/Fast/com.apple.container", "start /R"])
    }

    @Test func aFailedStartGoesBack() async throws {
        let env = FakeMoveEnvironment(listings: [same], failStartOn: "/Volumes/Fast/com.apple.container")
        do {
            try await DataRootMover(environment: env).run(plan, totalBytes: 1) { _ in }
            Issue.record("must fail")
        } catch let error as DataRootMoveError {
            if case .servicesDidNotStart = error {} else { Issue.record("wrong error \(error)") }
        }
        let saved = env.savedRoots
        #expect(saved.map(\.path) == ["/Volumes/Fast/com.apple.container", "/R"])
        let calls = env.calls
        #expect(calls.suffix(2) == ["remove /Volumes/Fast/com.apple.container", "start /R"])
    }

    @Test func missingResourcesAfterTheStartGoBack() async throws {
        let fewer = StorageListing(containers: 2, images: 1, volumes: 1)
        let env = FakeMoveEnvironment(listings: [same, fewer])
        await #expect(throws: DataRootMoveError.listingChanged(before: same, after: fewer)) {
            try await DataRootMover(environment: env).run(plan, totalBytes: 1) { _ in }
        }
        let saved = env.savedRoots
        #expect(saved.last?.path == "/R")
    }

    @Test func neverDeletesTheActiveRoot() async throws {
        let env = FakeMoveEnvironment(listings: [same])
        let mover = DataRootMover(environment: env)
        await #expect(throws: DataRootMoveError.activeRoot) {
            try await mover.deleteOldRoot("/Volumes/Fast", activeRoot: "/Volumes/Fast/com.apple.container")
        }
        await #expect(throws: DataRootMoveError.activeRoot) {
            try await mover.deleteOldRoot("/R", activeRoot: "/R/")
        }
        try await mover.deleteOldRoot("/R", activeRoot: "/Volumes/Fast/com.apple.container")
        #expect(env.calls == ["remove /R"])
    }

    @Test func listingCovers() {
        #expect(StorageListing(containers: 3, images: 3, volumes: 1).covers(same))
        #expect(!StorageListing(containers: 1, images: 3, volumes: 1).covers(same))
    }

    @Test func everyErrorHasAMessage() {
        let errors: [DataRootMoveError] = [
            .sameLocation, .destinationInsideSource, .destinationNotEmpty("/x"), .diskRefused([.readOnly]),
            .verifyFailed(["a"]), .servicesDidNotStart("x"), .listingChanged(before: same, after: same), .activeRoot
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
        for step in DataRootMoveStep.allCases { #expect(!step.title.isEmpty) }
    }
}

struct TreeManifestTests {
    @Test func reportsMissingChangedAndExtraPaths() {
        let a = TreeManifest(entries: [
            "x": .init(kind: .file, size: 1), "y": .init(kind: .directory), "l": .init(kind: .symlink, linkTarget: "x")
        ])
        var b = a
        #expect(a.differences(from: b).isEmpty)
        b.entries["x"]?.size = 2
        b.entries.removeValue(forKey: "y")
        b.entries["z"] = .init(kind: .file)
        b.entries["l"]?.linkTarget = "q"
        #expect(a.differences(from: b) == ["l", "x", "y", "z"])
    }

    @Test func copyUsesCPArchiveMode() {
        #expect(TreeCopy.executable == "/bin/cp")
        #expect(TreeCopy.arguments(from: "/R/", to: "/Volumes/F/c") == ["-a", "/R", "/Volumes/F/c"])
        #expect(LiveDataRootMoveEnvironment.countJSONArray(#"[{"a":1},{"b":2}]"#) == 2)
        #expect(LiveDataRootMoveEnvironment.countJSONArray("not json") == 0)
    }
}

// MARK: - Unplugged disks

struct DiskPresenceTests {
    @Test func bootDiskPathsAreAlwaysConnected() {
        let presence = DiskPresence(mounted: ["/Volumes/Fast/"])
        #expect(presence.isConnected("/Users/me/data"))
        #expect(presence.isConnected("/Volumes/Fast/data"))
        #expect(!presence.isConnected("/Volumes/Gone/data"))
        #expect(presence.missingDisk(for: "/Volumes/Gone/data") == "Gone")
    }

    @Test func findsMissingDisksOfAContainer() throws {
        let presence = DiskPresence(mounted: ["/Volumes/Fast"])
        let c = try container(id: "web", running: false, mounts: [
            ("/Volumes/Gone/site", nil), ("/Volumes/Gone/logs", nil), ("/Volumes/Fast/x", nil),
            ("cache", "cache"), ("photos", "photos")
        ])
        #expect(presence.missingDisks(for: c) == ["Gone"])
        #expect(presence.missingDisks(for: c, folderVolumes: ["photos": "/Volumes/Archive/photos"]) == ["Gone", "Archive"])
    }

    @Test func runningContainersOnADisk() throws {
        let a = try container(id: "a", running: true, mounts: [("/Volumes/Fast/a", nil)])
        let b = try container(id: "b", running: false, mounts: [("/Volumes/Fast/b", nil)])
        let c = try container(id: "c", running: true, mounts: [("/Volumes/Other/c", nil)])
        #expect(DiskPresence.runningContainers(on: "/Volumes/Fast", in: [a, b, c]).map(\.id) == ["a"])
    }

    @Test func ejectWarningListsServicesAndRunningContainers() throws {
        let a = try container(id: "web", running: true, mounts: [("/Volumes/Fast/site", nil)])
        let b = try container(id: "old", running: false, mounts: [("/Volumes/Fast/old", nil)])
        let warning = try #require(EjectWarning.make(
            mountPoint: "/Volumes/Fast", containers: [a, b], dataRoot: "/Volumes/Fast/com.apple.container"
        ))
        #expect(warning.diskName == "Fast")
        #expect(warning.users.count == 2 && warning.users.last == "web")
        #expect(warning.body.contains("web") && warning.title.contains("Fast"))
        #expect(EjectWarning.make(mountPoint: "/Volumes/Fast", containers: [b], dataRoot: "/Users/me/root") == nil)
        #expect(EjectWarning.make(mountPoint: "/Volumes/Other", containers: [a], dataRoot: nil) == nil)
    }

    @Test func blockMessagesNameTheDisks() {
        #expect(StorageBlock(disks: ["Fast"]).message.contains("Fast"))
        #expect(StorageBlock(disks: ["A", "B"]).message.contains("B"))
        #expect(StorageBlock(disks: ["A"]).startMessage.contains("A"))
        #expect(StorageBlock(disks: ["A"]).hostMessage.contains("A"))
    }
}

// MARK: - Folder volumes

struct FolderVolumeTests {
    @Test func validatesNames() {
        #expect(FolderVolumeRules.isValidName("db-data"))
        #expect(FolderVolumeRules.isValidName("a1.b_c"))
        #expect(!FolderVolumeRules.isValidName("a"))
        #expect(!FolderVolumeRules.isValidName("-db"))
        #expect(!FolderVolumeRules.isValidName("db data"))
        #expect(!FolderVolumeRules.isValidName("дата"))
        #expect(!FolderVolumeRules.isValidName("db/x"))
    }

    @Test func dockerBindOptionsRoundTrip() {
        let options = FolderVolumeRules.dockerBindOptions(path: "/Volumes/Fast/db/")
        #expect(options == ["type": "none", "o": "bind", "device": "/Volumes/Fast/db"])
        #expect(FolderVolumeRules.dockerBindPath(options: options) == "/Volumes/Fast/db")
        #expect(FolderVolumeRules.dockerBindPath(options: ["type": "nfs", "o": "addr=1", "device": ":/x"]) == nil)
        #expect(FolderVolumeRules.dockerBindPath(options: nil) == nil)
        #expect(FolderVolumeRules.folder(named: "db", in: "/Volumes/Fast/") == "/Volumes/Fast/db")
    }

    @MainActor @Test func storeAddsAndRemoves() throws {
        let store = FolderVolumeStore(fileURL: nil)
        let host = UUID(), other = UUID()
        let volume = try store.add(name: "photos", path: "/Volumes/Fast/photos", hostID: host)
        #expect(volume.bindSpec(target: "/data", readOnly: true) == "/Volumes/Fast/photos:/data:ro")
        #expect(throws: FolderVolumeError.nameTaken("photos")) {
            try store.add(name: "photos", path: "/Volumes/Fast/p2", hostID: host)
        }
        #expect(throws: FolderVolumeError.nameTaken("db")) {
            try store.add(name: "db", path: "/Volumes/Fast/db", hostID: host, takenNames: ["db"])
        }
        #expect(throws: FolderVolumeError.notAbsolute("x")) { try store.add(name: "xy", path: "x", hostID: host) }
        try store.add(name: "photos", path: "/Volumes/Other/photos", hostID: other)
        #expect(store.volumes(for: host).map(\.name) == ["photos"])
        #expect(store.paths(for: other) == ["photos": "/Volumes/Other/photos"])
        try store.remove(name: "photos", hostID: host)
        #expect(store.volumes(for: host).isEmpty)
        #expect(store.volumes(for: other).count == 1)
    }
}

// MARK: - Volume and image transfers

struct VolumeTransferTests {
    @Test func copyJobMountsBothSides() {
        let job = VolumeTransferPlan.copy(from: .named("db"), to: .folder("/Volumes/Fast/db/"))
        #expect(job.appleArguments(name: "gantry-copy-1") == [
            "run", "--rm", "--name", "gantry-copy-1", "-v", "db:/from:ro", "-v", "/Volumes/Fast/db:/to",
            HelperJob.defaultImage, "sh", "-c", "cp -a /from/. /to/", "sh"
        ])
        let request = job.dockerRequest(name: "gantry-copy-1")
        #expect(request.hostConfig?.binds == ["db:/from:ro", "/Volumes/Fast/db:/to"])
        #expect(request.cmd == ["sh", "-c", "cp -a /from/. /to/", "sh"])
        #expect(request.labels[HelperJob.label] == "1")
    }

    @Test func exportAndImportPassFileNamesAsArguments() {
        let export = VolumeTransferPlan.exportTar(.named("db"), toFolder: "/Volumes/Fast/backups", fileName: "a b;rm.tar")
        #expect(export.script == "tar -cf \"/out/$1\" -C /from .")
        #expect(export.arguments == ["a b;rm.tar"])
        #expect(export.mounts.map(\.spec) == ["db:/from:ro", "/Volumes/Fast/backups:/out"])
        let restore = VolumeTransferPlan.importTar(file: "/Volumes/Fast/backups/db.tar", into: .named("db2"))
        #expect(restore.mounts.map(\.spec) == ["/Volumes/Fast/backups:/in:ro", "db2:/to"])
        #expect(restore.arguments == ["db.tar"])
        #expect(restore.appleArguments(name: "n").suffix(2) == ["sh", "db.tar"])
    }

    @Test func archiveNames() {
        let date = Date(timeIntervalSince1970: 0)
        #expect(VolumeTransferPlan.archiveName(for: "db", date: date) == "db-19700101-000000.tar")
        #expect(ImageArchive.archiveName(for: "docker.io/library/nginx:1.27") == "nginx-1.27.tar")
        #expect(ImageArchive.archiveName(for: ":") == "image.tar")
        #expect(ImageArchive.appleSaveArguments(references: ["nginx:1"], to: "/Volumes/F/n.tar")
            == ["image", "save", "--output", "/Volumes/F/n.tar", "nginx:1"])
        #expect(ImageArchive.appleLoadArguments(from: "/Volumes/F/n.tar") == ["image", "load", "--input", "/Volumes/F/n.tar"])
        #expect(HelperJob.containerName("copy").hasPrefix("gantry-copy-"))
    }

    @Test func refusesAnExportLargerThanTheFreeSpace() {
        #expect(VolumeTransferPlan.spaceIssue(needed: 11, on: disk("/Volumes/F", free: 10))
            == .notEnoughSpace(needed: 11, available: 10))
        #expect(VolumeTransferPlan.spaceIssue(needed: 10, on: disk("/Volumes/F", free: 10)) == nil)
        #expect(VolumeTransferPlan.spaceIssue(needed: 10, on: nil) == nil)
    }

    @Test func replacesTheMovedSourceOnly() {
        let binds = ["db:/var/lib/db", "/Volumes/Fast/db:/backup:ro", "logs:/logs", "dbx:/x"]
        #expect(VolumeTransferPlan.replacingSource(in: binds, old: .named("db"), new: .folder("/Volumes/Fast/newdb"))
            == ["/Volumes/Fast/newdb:/var/lib/db", "/Volumes/Fast/db:/backup:ro", "logs:/logs", "dbx:/x"])
        #expect(VolumeTransferPlan.replacingSource(in: binds, old: .folder("/Volumes/Fast/db/"), new: .named("db2"))
            == ["db:/var/lib/db", "db2:/backup:ro", "logs:/logs", "dbx:/x"])
    }

    @Test func findsTheUsersOfAVolume() throws {
        let a = try container(id: "a", running: true, mounts: [("db", "db")])
        let b = try container(id: "b", running: false, mounts: [("/Volumes/Fast/db", nil)])
        let c = try container(id: "c", running: false, mounts: [("other", "other")])
        #expect(VolumeTransferPlan.users(of: .named("db"), in: [a, b, c]).map(\.id) == ["a"])
        #expect(VolumeTransferPlan.users(of: .folder("/Volumes/Fast/db/"), in: [a, b, c]).map(\.id) == ["b"])
    }
}

struct StorageFormatTests {
    @Test func zeroIsANumber() {
        #expect(StorageFormat.bytes(0).first?.isNumber == true)
        #expect(!StorageFormat.bytes(0).localizedCaseInsensitiveContains("zero"))
    }
}
