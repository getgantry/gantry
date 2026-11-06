import Foundation
import Testing
@testable import AppCore

@Suite struct LocalDockerPolicyTests {
    private let local = DockerHost(name: "Local", kind: .local)
    private let apple = DockerHost(name: "Apple Container", kind: .appleContainer)

    @Test func hidesLocalWithoutDockerWhenAppleCLIExists() {
        let action = LocalDockerPolicy.action(
            hosts: [local, apple], choice: .automatic, socketFound: false, appleCLIFound: true
        )
        #expect(action == .hide(local.id))
        #expect(LocalDockerPolicy.choice(after: action, from: .automatic) == .autoHidden)
    }

    @Test func keepsLocalWhenDockerExistsOrNoAppleCLI() {
        #expect(LocalDockerPolicy.action(
            hosts: [local, apple], choice: .automatic, socketFound: true, appleCLIFound: true
        ) == .none)
        // Without the apple CLI, the Local host is all the app has.
        #expect(LocalDockerPolicy.action(
            hosts: [local], choice: .automatic, socketFound: false, appleCLIFound: false
        ) == .none)
    }

    @Test func customSocketHostIsNeverHidden() {
        let custom = DockerHost(name: "Mine", kind: .local, socketPathOverride: "/tmp/gantry-fix.sock")
        #expect(LocalDockerPolicy.action(
            hosts: [custom, apple], choice: .automatic, socketFound: false, appleCLIFound: true
        ) == .none)
    }

    @Test func restoresWhenDockerAppearsAfterAutoHide() {
        let action = LocalDockerPolicy.action(
            hosts: [apple], choice: .autoHidden, socketFound: true, appleCLIFound: true
        )
        #expect(action == .restore)
        #expect(LocalDockerPolicy.choice(after: action, from: .autoHidden) == .automatic)
        #expect(LocalDockerPolicy.action(
            hosts: [apple], choice: .autoHidden, socketFound: false, appleCLIFound: true
        ) == .none)
    }

    @Test func explicitChoicesWin() {
        #expect(LocalDockerPolicy.action(
            hosts: [apple], choice: .removed, socketFound: true, appleCLIFound: true
        ) == .none)
        #expect(LocalDockerPolicy.action(
            hosts: [local, apple], choice: .added, socketFound: false, appleCLIFound: true
        ) == .none)
    }

    @Test func seedHostsFitTheMac() {
        let appleOnly = LocalDockerPolicy.seedHosts(socketFound: false, appleCLIFound: true)
        #expect(appleOnly.hosts.map(\.isAppleContainer) == [true])
        #expect(appleOnly.choice == .autoHidden)

        let dockerOnly = LocalDockerPolicy.seedHosts(socketFound: true, appleCLIFound: false)
        #expect(dockerOnly.hosts.map(\.isLocal) == [true])
        #expect(dockerOnly.choice == .automatic)

        let both = LocalDockerPolicy.seedHosts(socketFound: true, appleCLIFound: true)
        #expect(both.hosts.count == 2)

        let neither = LocalDockerPolicy.seedHosts(socketFound: false, appleCLIFound: false)
        #expect(neither.hosts.map(\.isLocal) == [true])
    }
}

/// AppModel applies the policy against a temp hosts.json and a private
/// UserDefaults suite, so the Mac's real settings are never touched.
@MainActor
@Suite(.serialized)
struct LocalDockerModelTests {
    private func withIsolatedStore(_ body: (UserDefaults) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-fix-hosts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = getenv("GANTRY_HOSTS_PATH").map { String(cString: $0) }
        setenv("GANTRY_HOSTS_PATH", dir.appendingPathComponent("hosts.json").path, 1)
        let suite = "gantry-fix-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            if let previous { setenv("GANTRY_HOSTS_PATH", previous, 1) } else { unsetenv("GANTRY_HOSTS_PATH") }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(defaults)
    }

    @Test func appleOnlyFirstLaunchHasNoLocalHost() {
        withIsolatedStore { defaults in
            let model = AppModel(detection: .fixed(socketFound: false, appleCLIFound: true), defaults: defaults)
            #expect(model.sessions.map(\.host.isAppleContainer) == [true])
            #expect(model.localDockerChoice == .autoHidden)
        }
    }

    @Test func existingLocalHostIsHiddenThenRestored() {
        withIsolatedStore { defaults in
            // An install from before: Local plus Apple, with Docker present.
            let first = AppModel(detection: .fixed(socketFound: true, appleCLIFound: true), defaults: defaults)
            #expect(first.sessions.count == 2)

            // Docker goes away: the Local host is hidden and stays hidden.
            let noDocker = AppModel(detection: .fixed(socketFound: false, appleCLIFound: true), defaults: defaults)
            #expect(!noDocker.sessions.contains { $0.host.isLocal })
            #expect(HeadlessDocker.loadHosts().allSatisfy { !$0.isLocal })

            // Docker comes back: the Local host returns.
            let back = AppModel(detection: .fixed(socketFound: true, appleCLIFound: true), defaults: defaults)
            #expect(back.sessions.first?.host.isLocal == true)
        }
    }

    @Test func removedLocalHostStaysRemoved() {
        withIsolatedStore { defaults in
            let model = AppModel(detection: .fixed(socketFound: true, appleCLIFound: true), defaults: defaults)
            let local = model.sessions.first { $0.host.isLocal }!
            model.removeHost(id: local.id)
            #expect(model.localDockerChoice == .removed)

            let again = AppModel(detection: .fixed(socketFound: true, appleCLIFound: true), defaults: defaults)
            #expect(!again.sessions.contains { $0.host.isLocal })
        }
    }

    @Test func addedLocalHostIsNotAutoHidden() {
        withIsolatedStore { defaults in
            let model = AppModel(detection: .fixed(socketFound: false, appleCLIFound: true), defaults: defaults)
            model.addHost(DockerHost(name: "Local", kind: .local))
            #expect(model.localDockerChoice == .added)
            model.applyLocalDockerPolicy()
            #expect(model.sessions.contains { $0.host.isLocal })
        }
    }

    @Test func missingSocketIsNeutralNotFailed() async {
        let session = HostSession(host: DockerHost(name: "Local", kind: .local))
        session.discoverDockerSocket = { nil }
        await session.connect()
        // Grey, not red: not counted as unreachable, no alert, no retry loop.
        #expect(session.status == .disconnected)
        #expect(session.dockerNotInstalled)
        #expect(session.lastError == nil)
    }
}
