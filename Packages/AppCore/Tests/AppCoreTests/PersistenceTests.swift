import Foundation
import Testing
@testable import AppCore

/// Persistence tests run serialized: they share the process-wide
/// `GANTRY_HOSTS_PATH` environment override, so they must not interleave.
@MainActor
@Suite(.serialized)
struct PersistenceTests {
    /// Points `HostsStore.fileURL()` at a fresh temp file for the duration of
    /// `body`, then restores the previous value. CRITICAL: this is why the
    /// machine's real `~/Library/Application Support/Gantry/hosts.json` is never
    /// touched by the suite.
    private func withTempHostsFile(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcore-hosts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hosts.json")

        let previous = getenv("GANTRY_HOSTS_PATH").map { String(cString: $0) }
        setenv("GANTRY_HOSTS_PATH", file.path, 1)
        defer {
            if let previous { setenv("GANTRY_HOSTS_PATH", previous, 1) }
            else { unsetenv("GANTRY_HOSTS_PATH") }
            try? FileManager.default.removeItem(at: dir)
        }
        try? body(file)
    }

    @Test func firstRunSeedsLocalHost() {
        withTempHostsFile { file in
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let model = AppModel()
            #expect(model.sessions.count == 1)
            #expect(model.sessions.first?.host.isLocal == true)
            // The default was persisted.
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func addRemovePersistAcrossReload() {
        withTempHostsFile { _ in
            let model = AppModel()
            let ssh = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
            model.addHost(ssh)
            #expect(model.sessions.count == 2)

            // A fresh model reads the same file.
            let reloaded = AppModel()
            #expect(reloaded.sessions.count == 2)
            #expect(reloaded.session(id: ssh.id) != nil)

            reloaded.removeHost(id: ssh.id)
            #expect(reloaded.sessions.count == 1)

            let again = AppModel()
            #expect(again.sessions.count == 1)
        }
    }

    @Test func updateHostNameOnlyKeepsSession() {
        withTempHostsFile { _ in
            let model = AppModel()
            let ssh = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
            model.addHost(ssh)
            let original = model.session(id: ssh.id)

            var renamed = ssh
            renamed.name = "Renamed"
            let result = model.updateHost(renamed)
            // Cosmetic-only change still produces a new persisted session
            // (host value differs) but keeps the same id.
            #expect(result?.id == ssh.id)
            #expect(model.session(id: ssh.id)?.host.name == "Renamed")
            _ = original
        }
    }

    @Test func updateHostConnectionChangeReplacesSession() {
        withTempHostsFile { _ in
            let model = AppModel()
            let ssh = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
            model.addHost(ssh)
            let original = model.session(id: ssh.id)

            var changed = ssh
            changed.kind = .ssh(SSHEndpoint(host: "different-host"))
            let result = model.updateHost(changed)
            #expect(result?.id == ssh.id)
            // Connection-relevant change -> replacement instance.
            #expect(result !== original)
        }
    }

    @Test func updateHostUnknownIDReturnsNil() {
        withTempHostsFile { _ in
            let model = AppModel()
            let stray = DockerHost(name: "Nope", kind: .local)
            #expect(model.updateHost(stray) == nil)
        }
    }

    @Test func updateHostNoChangeKeepsSameInstance() {
        withTempHostsFile { _ in
            let model = AppModel()
            let ssh = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
            model.addHost(ssh)
            let original = model.session(id: ssh.id)
            // Same host value -> same session instance returned.
            let result = model.updateHost(ssh)
            #expect(result === original)
        }
    }

    @Test func corruptFileFallsBackToDefault() {
        withTempHostsFile { file in
            try? Data("not json".utf8).write(to: file)
            let model = AppModel()
            #expect(model.sessions.count == 1)
            #expect(model.sessions.first?.host.isLocal == true)
        }
    }

    // MARK: - HeadlessDocker.loadHosts shares the same file

    @Test func headlessLoadHostsReadsSameFile() {
        withTempHostsFile { _ in
            let model = AppModel()
            let ssh = DockerHost(name: "Box", kind: .ssh(SSHEndpoint(host: "h")))
            model.addHost(ssh)

            let hosts = HeadlessDocker.loadHosts()
            #expect(hosts.count == 2)
            #expect(hosts.contains { $0.id == ssh.id })
        }
    }

    // MARK: - HostsStore.fileURL real (non-overridden) path

    @Test func fileURLResolvesRealApplicationSupportWhenNoOverride() {
        // Ensure no override leaks in from another test, then resolve the real
        // Application Support path. We only READ the URL — never write — so the
        // machine's real hosts.json is untouched.
        let previous = getenv("GANTRY_HOSTS_PATH").map { String(cString: $0) }
        unsetenv("GANTRY_HOSTS_PATH")
        defer { if let previous { setenv("GANTRY_HOSTS_PATH", previous, 1) } }

        let url = HostsStore.fileURL()
        #expect(url != nil)
        #expect(url?.lastPathComponent == "hosts.json")
        #expect(url?.path.contains("Gantry") == true)
        #expect(url?.path.contains("Application Support") == true)
    }

    @Test func fileURLHonorsEmptyOverrideByIgnoringIt() {
        let previous = getenv("GANTRY_HOSTS_PATH").map { String(cString: $0) }
        setenv("GANTRY_HOSTS_PATH", "", 1)
        defer {
            if let previous { setenv("GANTRY_HOSTS_PATH", previous, 1) }
            else { unsetenv("GANTRY_HOSTS_PATH") }
        }
        // Empty override is ignored -> falls through to real path.
        #expect(HostsStore.fileURL()?.lastPathComponent == "hosts.json")
    }

    @Test func headlessLoadHostsEmptyWhenMissing() {
        withTempHostsFile { file in
            // No file on disk -> empty (headless does not synthesize a default).
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(HeadlessDocker.loadHosts().isEmpty)
        }
    }
}
