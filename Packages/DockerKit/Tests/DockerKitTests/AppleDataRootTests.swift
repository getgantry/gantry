import Foundation
import Testing
@testable import DockerKit

struct AppleDataRootTests {
    @Test func defaultRootStartsWithoutAppRoot() {
        let root = AppleDataRoot()
        #expect(!root.isCustom)
        #expect(root.startArguments == ["system", "start", "--disable-kernel-install"])
        #expect(root.cliEnvironment.isEmpty)
        #expect(root.startCommand == "container system start")
    }

    @Test func defaultPathWithSlashIsNotCustom() {
        let root = AppleDataRoot(path: AppleDataRoot.defaultPath + "/")
        #expect(!root.isCustom)
        #expect(root.startArguments.count == 3)
    }

    @Test func customRootAddsFlagAndEnvironment() {
        let root = AppleDataRoot(path: "  /Volumes/My Disk/com.apple.container ")
        #expect(root.isCustom)
        #expect(root.startArguments.suffix(2) == ["--app-root", "/Volumes/My Disk/com.apple.container"])
        #expect(root.cliEnvironment == ["CONTAINER_APP_ROOT": "/Volumes/My Disk/com.apple.container"])
        #expect(root.startCommand == "container system start --app-root '/Volumes/My Disk/com.apple.container'")
        #expect(AppleDataRoot(path: "/Volumes/Fast/c").startCommand == "container system start --app-root /Volumes/Fast/c")
    }

    @Test func emptyPathIsDefault() {
        #expect(AppleDataRoot(path: "  ").path == nil)
    }

    @Test func storeRoundTripsAndDropsDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gstore-\(UUID().uuidString)/root.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppleDataRootStore(fileURL: url)
        #expect(store.load() == AppleDataRoot())
        try store.save(AppleDataRoot(path: "/Volumes/Fast/com.apple.container"))
        #expect(store.load().path == "/Volumes/Fast/com.apple.container")
        try store.save(AppleDataRoot(path: AppleDataRoot.defaultPath))
        #expect(store.load().path == nil)
    }
}
