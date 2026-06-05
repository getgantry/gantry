import Testing
import Foundation
import Crypto
@testable import SSHKit

// MARK: - Helpers

private func makeTempFile(_ contents: String, ext: String = "") throws -> String {
    let dir = NSTemporaryDirectory()
    let name = "sshkit-test-\(UUID().uuidString)\(ext)"
    let path = (dir as NSString).appendingPathComponent(name)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

// MARK: - ssh_config parsing

@Test func sshConfigResolvesPatternsFirstWinsAndPort() throws {
    let config = """
    # Gantry test config
    Host prod-*
        HostName prod.example.com
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_prod
        IdentityFile ~/.ssh/id_prod_backup

    Host *
        User fallback
        Port 9999
        IdentityFile ~/.ssh/id_default
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "prod-web1", configPath: path)

    #expect(resolved.hostName == "prod.example.com")
    // First-wins: prod-* sets user/port before the catch-all.
    #expect(resolved.user == "deploy")
    #expect(resolved.port == 2222)
    // Port must be parsed as an Int.
    #expect(type(of: resolved.port) == Int.self)
    // IdentityFile is additive across matching blocks, in order, deduped.
    #expect(resolved.identityFiles.count == 3)
    #expect(resolved.identityFiles[0].hasSuffix("/.ssh/id_prod"))
    #expect(resolved.identityFiles[1].hasSuffix("/.ssh/id_prod_backup"))
    #expect(resolved.identityFiles[2].hasSuffix("/.ssh/id_default"))
}

@Test func sshConfigMissingFileReturnsDefaults() {
    let resolved = SSHConfig.resolve(host: "myhost", configPath: "/nonexistent/path/ssh_config")
    #expect(resolved.hostName == "myhost")
    #expect(resolved.port == 22)
    #expect(resolved.user == nil)
    #expect(resolved.identityFiles.isEmpty)
}

@Test func sshConfigEqualsSeparatorAndQuestionMarkGlob() throws {
    let config = """
    Host db?
        HostName=db.internal
        Port=15
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let match = SSHConfig.resolve(host: "db1", configPath: path)
    #expect(match.hostName == "db.internal")
    #expect(match.port == 15)

    // "db12" is two chars after "db" so '?' (single char) must not match.
    let noMatch = SSHConfig.resolve(host: "db12", configPath: path)
    #expect(noMatch.hostName == "db12")
    #expect(noMatch.port == 22)
}

// MARK: - known_hosts parsing

@Test func knownHostsTrustedViaSystemFileWithBracketPort() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let knownHosts = """
    # comment line
    |1|hashedhostshouldbeskipped= ssh-ed25519 AAAAignored
    [host.example.com]:2222 ssh-ed25519 \(pub)
    """
    let khPath = try makeTempFile(knownHosts)
    let appPath = try makeTempFile("[]")
    defer {
        try? FileManager.default.removeItem(atPath: khPath)
        try? FileManager.default.removeItem(atPath: appPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let presented = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)

    #expect(store.evaluate(host: "host.example.com", port: 2222, presented: presented) == .trusted)
    // Wrong port must not match the bracketed entry.
    #expect(store.evaluate(host: "host.example.com", port: 22, presented: presented) == .unknown)
}

@Test func knownHostsBareTokenMatchesDefaultPort() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let knownHosts = "alpha.example.com,1.2.3.4 ssh-ed25519 \(pub)"
    let khPath = try makeTempFile(knownHosts)
    let appPath = try makeTempFile("[]")
    defer {
        try? FileManager.default.removeItem(atPath: khPath)
        try? FileManager.default.removeItem(atPath: appPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let presented = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)
    #expect(store.evaluate(host: "alpha.example.com", port: 22, presented: presented) == .trusted)
    #expect(store.evaluate(host: "1.2.3.4", port: 22, presented: presented) == .trusted)
}

@Test func knownHostsMismatchVerdict() throws {
    let storedPub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let differentPub = "AAAAC3NzaC1lZDI1NTE5AAAAICCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
    let knownHosts = "evil.example.com ssh-ed25519 \(storedPub)"
    let khPath = try makeTempFile(knownHosts)
    let appPath = try makeTempFile("[]")
    defer {
        try? FileManager.default.removeItem(atPath: khPath)
        try? FileManager.default.removeItem(atPath: appPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let presented = HostKeyCandidate(keyType: "ssh-ed25519", base64: differentPub)
    let expectedFingerprint = HostKeyCandidate(keyType: "ssh-ed25519", base64: storedPub).fingerprintSHA256

    #expect(store.evaluate(host: "evil.example.com", port: 22, presented: presented) == .mismatch(expected: expectedFingerprint))
}

@Test func knownHostsPersistRoundTrip() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let appDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sshkit-store-\(UUID().uuidString)")
    let appPath = (appDir as NSString).appendingPathComponent("trusted_hosts.json")
    let khPath = try makeTempFile("")
    defer {
        try? FileManager.default.removeItem(atPath: appDir)
        try? FileManager.default.removeItem(atPath: khPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let candidate = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)

    #expect(store.evaluate(host: "new.example.com", port: 22, presented: candidate) == .unknown)
    store.persist(host: "new.example.com", port: 22, candidate: candidate)
    #expect(store.evaluate(host: "new.example.com", port: 22, presented: candidate) == .trusted)
}

// MARK: - Fingerprint computation

@Test func fingerprintMatchesIndependentComputationAndFormat() {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let candidate = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)

    // Self-verify the roundtrip: SHA256 of the decoded blob, base64, no padding.
    let blob = Data(base64Encoded: pub)!
    let digest = SHA256.hash(data: blob)
    var expected = Data(digest).base64EncodedString()
    while expected.hasSuffix("=") { expected.removeLast() }

    #expect(candidate.fingerprintSHA256 == "SHA256:" + expected)
    #expect(candidate.fingerprintSHA256.hasPrefix("SHA256:"))
    #expect(!candidate.fingerprintSHA256.hasSuffix("="))
    #expect(candidate.openSSHString == "ssh-ed25519 " + pub)
}

// MARK: - KeyLoader error mapping

@Test func keyLoaderFileNotFound() {
    #expect(throws: SSHKeyError.self) {
        _ = try SSHKeyLoader.load(contentsOf: "/nonexistent/key", passphrase: nil)
    }
    do {
        _ = try SSHKeyLoader.load(contentsOf: "/nonexistent/key", passphrase: nil)
    } catch let error as SSHKeyError {
        guard case .fileNotFound = error else {
            Issue.record("expected .fileNotFound, got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func keyLoaderGarbageFileUnsupportedFormat() throws {
    let path = try makeTempFile("this is not a key at all\njust some text\n")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
        Issue.record("expected an SSHKeyError")
    } catch let error as SSHKeyError {
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(error)")
            return
        }
    }
}

@Test func keyLoaderLegacyPemUnsupported() throws {
    let path = try makeTempFile("-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----\n")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
        Issue.record("expected an SSHKeyError")
    } catch let error as SSHKeyError {
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(error)")
            return
        }
    }
}

@Test func keyLoaderCorruptOpenSSHKeyParseFailed() throws {
    // Has the marker but the base64 payload is junk: should not be unsupportedFormat.
    let path = try makeTempFile("-----BEGIN OPENSSH PRIVATE KEY-----\nbm90LWEta2V5\n-----END OPENSSH PRIVATE KEY-----\n")
    defer { try? FileManager.default.removeItem(atPath: path) }

    do {
        _ = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
        Issue.record("expected an SSHKeyError")
    } catch let error as SSHKeyError {
        switch error {
        case .unsupportedFormat:
            Issue.record("a marked-but-corrupt key should not be .unsupportedFormat")
        default:
            break // .parseFailed or similar is acceptable
        }
    }
}

@Test func sshKitInfoVersion() {
    #expect(SSHKitInfo.version == "0.1.0")
}

// MARK: - ProxyJump resolution

@Test func proxyJumpSingleHopResolvesThroughAlias() throws {
    let config = """
    Host bastion
        HostName 198.51.100.1
        User jumper
        Port 2200
        IdentityFile ~/.ssh/id_bastion

    Host inner
        HostName 10.0.0.5
        User app
        ProxyJump bastion
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "inner", configPath: path)
    #expect(resolved.hostName == "10.0.0.5")
    #expect(resolved.jumps.count == 1)
    let hop = try #require(resolved.jumps.first)
    #expect(hop.hostName == "198.51.100.1")
    #expect(hop.user == "jumper")
    #expect(hop.port == 2200)
    #expect(hop.identityFiles.first?.hasSuffix("/.ssh/id_bastion") == true)
}

@Test func proxyJumpInlineUserPortAndChain() throws {
    let config = """
    Host first
        HostName first.example.com

    Host target
        HostName 10.1.1.1
        ProxyJump admin@first:2222,second.example.com
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "target", configPath: path)
    #expect(resolved.jumps.count == 2)
    // Inline user@ and :port beat the alias's values.
    #expect(resolved.jumps[0].hostName == "first.example.com")
    #expect(resolved.jumps[0].user == "admin")
    #expect(resolved.jumps[0].port == 2222)
    // Bare hostnames work without a config entry.
    #expect(resolved.jumps[1].hostName == "second.example.com")
    #expect(resolved.jumps[1].port == 22)
}

@Test func proxyJumpRecursiveAndCycleGuarded() throws {
    let config = """
    Host outer
        HostName outer.example.com

    Host middle
        HostName middle.example.com
        ProxyJump outer

    Host deep
        HostName 10.9.9.9
        ProxyJump middle

    Host loopA
        HostName a.example.com
        ProxyJump loopB

    Host loopB
        HostName b.example.com
        ProxyJump loopA
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    // A hop with its own ProxyJump flattens outermost-first.
    let deep = SSHConfig.resolve(host: "deep", configPath: path)
    #expect(deep.jumps.map(\.hostName) == ["outer.example.com", "middle.example.com"])

    // Mutual jumps must not recurse forever.
    let loop = SSHConfig.resolve(host: "loopA", configPath: path)
    #expect(loop.jumps.map(\.hostName) == ["b.example.com"])
}

@Test func proxyJumpNoneIsDirect() throws {
    let config = """
    Host direct
        HostName 10.2.2.2
        ProxyJump none
    """
    let path = try makeTempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(SSHConfig.resolve(host: "direct", configPath: path).jumps.isEmpty)
}
