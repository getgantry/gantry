import Foundation
import Testing
@testable import AppCore

// MARK: - ResolvedSSHEndpoint (via injected temp ssh_config)

@Suite struct ResolvedSSHEndpointTests {
    /// Writes a temp ssh_config and returns its path; caller cleans up.
    private func writeConfig(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appcore-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test func resolvesAliasToHostNameUserPort() throws {
        let path = try writeConfig("""
        Host mybox
            HostName 203.0.113.7
            User deploy
            Port 2200
            IdentityFile ~/.ssh/special_key
        """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let endpoint = SSHEndpoint(host: "mybox")
        let resolved = ResolvedSSHEndpoint.resolve(endpoint, configPath: path)
        #expect(resolved.hostName == "203.0.113.7")
        #expect(resolved.username == "deploy")
        #expect(resolved.port == 2200)
        #expect(resolved.identityFiles.contains { $0.hasSuffix("special_key") })
    }

    @Test func explicitFieldsOverrideConfig() throws {
        let path = try writeConfig("""
        Host mybox
            HostName 203.0.113.7
            User deploy
            Port 2200
        """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        // User supplied an explicit non-default port and username.
        let endpoint = SSHEndpoint(host: "mybox", port: 9999, username: "alice")
        let resolved = ResolvedSSHEndpoint.resolve(endpoint, configPath: path)
        #expect(resolved.port == 9999)
        #expect(resolved.username == "alice")
        // HostName still comes from config.
        #expect(resolved.hostName == "203.0.113.7")
    }

    @Test func port22MeansDefaultLetsConfigWin() throws {
        let path = try writeConfig("""
        Host mybox
            HostName host.example
            Port 2222
        """)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let endpoint = SSHEndpoint(host: "mybox", port: 22)
        let resolved = ResolvedSSHEndpoint.resolve(endpoint, configPath: path)
        #expect(resolved.port == 2222)
    }

    @Test func noMatchFallsBackToInputAndCurrentUser() throws {
        let path = try writeConfig("Host other\n    HostName x\n")
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

        let endpoint = SSHEndpoint(host: "unmatched.example")
        let resolved = ResolvedSSHEndpoint.resolve(endpoint, configPath: path)
        #expect(resolved.hostName == "unmatched.example")
        #expect(resolved.port == 22)
        #expect(resolved.username == NSUserName())
    }

    @Test func missingConfigFileUsesDefaults() {
        let endpoint = SSHEndpoint(host: "h.example", username: "u")
        let resolved = ResolvedSSHEndpoint.resolve(
            endpoint,
            configPath: "/nonexistent/\(UUID().uuidString)/config"
        )
        #expect(resolved.hostName == "h.example")
        #expect(resolved.username == "u")
        #expect(resolved.port == 22)
    }
}

// MARK: - KeychainStore

@Suite struct KeychainStoreTests {
    @Test func accountNameBuilders() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        #expect(KeychainStore.sshPasswordAccount(hostID: id) == "ssh-password-\(id.uuidString)")
        #expect(KeychainStore.keyPassphraseAccount(hostID: id) == "key-passphrase-\(id.uuidString)")
        #expect(KeychainStore.service == "com.andrewkomkov.Gantry")
    }

    @Test func setGetDeleteRoundTrip() {
        // Unique account name so we never collide with real app secrets.
        let account = "appcore-test-\(UUID().uuidString)"
        defer { KeychainStore.delete(account: account) }

        // Absent initially.
        #expect(KeychainStore.get(account: account) == nil)

        // Set then read back.
        #expect(KeychainStore.set("s3cret", account: account))
        #expect(KeychainStore.get(account: account) == "s3cret")

        // Update path (item already present).
        #expect(KeychainStore.set("updated", account: account))
        #expect(KeychainStore.get(account: account) == "updated")

        // Delete.
        #expect(KeychainStore.delete(account: account))
        #expect(KeychainStore.get(account: account) == nil)

        // Deleting a missing item is treated as success.
        #expect(KeychainStore.delete(account: account))
    }
}
