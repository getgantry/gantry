import Testing
import Foundation
import Crypto
@testable import SSHKit

// Additional pure (no-network) unit tests raising coverage of the deterministic
// surface: error descriptions, ssh_config listHosts / edge cases, known_hosts
// store details, and KeyLoader paths exercised with throwaway generated keys.

// MARK: - Helpers

private func tempFile(_ contents: String, ext: String = "") throws -> String {
    let dir = NSTemporaryDirectory()
    let name = "sshkit-pure-\(UUID().uuidString)\(ext)"
    let path = (dir as NSString).appendingPathComponent(name)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

/// Generates an OpenSSH key pair with `ssh-keygen`, returning the private key
/// path. The caller is responsible for cleanup. Returns nil if ssh-keygen is
/// unavailable (it ships with macOS, so this should not happen here).
@discardableResult
private func generateKey(type: String, passphrase: String, bits: Int? = nil) -> String? {
    let dir = NSTemporaryDirectory()
    let path = (dir as NSString).appendingPathComponent("sshkit-key-\(UUID().uuidString)")
    let keygen = "/usr/bin/ssh-keygen"
    guard FileManager.default.fileExists(atPath: keygen) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: keygen)
    var args = ["-t", type, "-N", passphrase, "-f", path, "-q"]
    if let bits { args.append(contentsOf: ["-b", String(bits)]) }
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0,
          FileManager.default.fileExists(atPath: path) else { return nil }
    return path
}

private func removeKey(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + ".pub")
}

// MARK: - Error descriptions (pure)

@Test func sshKeyErrorDescriptionsAreNonEmpty() {
    let errors: [SSHKeyError] = [
        .fileNotFound("/tmp/k"),
        .unsupportedFormat("legacy."),
        .needsPassphrase,
        .wrongPassphrase,
        .parseFailed("boom")
    ]
    for error in errors {
        let description = error.errorDescription
        #expect(description != nil)
        #expect(!(description ?? "").isEmpty)
    }
    #expect(SSHKeyError.fileNotFound("/tmp/k").errorDescription?.contains("/tmp/k") == true)
    #expect(SSHKeyError.parseFailed("boom").errorDescription?.contains("boom") == true)
    #expect(SSHKeyError.needsPassphrase.errorDescription?.contains("passphrase") == true)
}

@Test func sshConnectErrorDescriptions() {
    #expect(SSHConnectError.unreachable("down").errorDescription?.contains("down") == true)
    #expect(SSHConnectError.authenticationFailed("nope").errorDescription?.contains("nope") == true)
    #expect(SSHConnectError.hostKeyRejected.errorDescription?.contains("rejected") == true)
    #expect(SSHConnectError.other("weird").errorDescription?.contains("weird") == true)
}

@Test func hostKeyMismatchErrorDescriptionMentionsHostAndFingerprints() {
    let error = HostKeyMismatchError(
        host: "h.example.com",
        expectedFingerprint: "SHA256:AAA",
        presentedFingerprint: "SHA256:BBB"
    )
    let description = try! #require(error.errorDescription)
    #expect(description.contains("h.example.com"))
    #expect(description.contains("SHA256:AAA"))
    #expect(description.contains("SHA256:BBB"))
    #expect(description.contains("man-in-the-middle"))
}

@Test func userRejectedHostKeyErrorDescription() {
    let description = UserRejectedHostKeyError().errorDescription
    #expect(description?.isEmpty == false)
    #expect(description?.contains("not trusted") == true)
}

// MARK: - SSHConfig.listHosts

@Test func sshConfigListHostsSkipsWildcardsNegationsAndDedupes() throws {
    let config = """
    Host alpha beta
        HostName a.example.com

    Host *
        User any

    Host gamma !excluded prod-*
        HostName g.example.com

    Host alpha
        Port 2222
    """
    let path = try tempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let hosts = SSHConfig.listHosts(configPath: path)
    // Concrete aliases only, in file order, deduped. Wildcards (*, prod-*),
    // negations (!excluded) are dropped; "alpha" appears once.
    #expect(hosts == ["alpha", "beta", "gamma"])
}

@Test func sshConfigListHostsMissingFileIsEmpty() {
    #expect(SSHConfig.listHosts(configPath: "/nonexistent/ssh/config").isEmpty)
}

// MARK: - SSHConfig.resolve / parse edge cases

@Test func sshConfigResolveNoMatchReturnsDefaults() throws {
    let config = """
    Host specific
        HostName s.example.com
        Port 2200
    """
    let path = try tempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "other", configPath: path)
    #expect(resolved.hostName == "other")
    #expect(resolved.port == 22)
    #expect(resolved.user == nil)
    #expect(resolved.identityFiles.isEmpty)
}

@Test func sshConfigParseHandlesQuotesCommentsBlankLinesAndUnknownKeywords() throws {
    let config = """

    # leading comment

    Host quoted
        HostName "quoted.example.com"
        User "deploy user"
        ProxyCommand something we ignore
        UnknownKeyword whatever
        IdentityFile "~/.ssh/quoted key"
    """
    let path = try tempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "quoted", configPath: path)
    #expect(resolved.hostName == "quoted.example.com")
    #expect(resolved.user == "deploy user")
    #expect(resolved.identityFiles.count == 1)
    #expect(resolved.identityFiles[0].hasSuffix("/.ssh/quoted key"))
}

@Test func sshConfigParseLineWithoutValueIsSkipped() throws {
    // A keyword with no value (just "Port") must not crash or set a value.
    let config = """
    Host h
        HostName h.example.com
        Port
    """
    let path = try tempFile(config)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let resolved = SSHConfig.resolve(host: "h", configPath: path)
    #expect(resolved.hostName == "h.example.com")
    #expect(resolved.port == 22)
}

@Test func sshConfigMatchesNegationPatternReturnsFalse() {
    #expect(SSHConfig.matches(pattern: "!nope", host: "nope") == false)
    #expect(SSHConfig.matches(pattern: "ho*", host: "host") == true)
    #expect(SSHConfig.matches(pattern: "exact", host: "exact") == true)
    #expect(SSHConfig.matches(pattern: "exact", host: "other") == false)
}

// MARK: - KnownHosts internals

@Test func knownHostsUnknownWhenStoredUnderDifferentAlgorithmOnly() throws {
    // Stored key is ed25519; presented is ecdsa for the same host: we know the
    // host but not under that algorithm, so the verdict is .unknown (not mismatch).
    let edPub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let knownHosts = "multi.example.com ssh-ed25519 \(edPub)"
    let khPath = try tempFile(knownHosts)
    let appPath = try tempFile("[]")
    defer {
        try? FileManager.default.removeItem(atPath: khPath)
        try? FileManager.default.removeItem(atPath: appPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let presentedEcdsa = HostKeyCandidate(
        keyType: "ecdsa-sha2-nistp256",
        base64: "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY="
    )
    #expect(store.evaluate(host: "multi.example.com", port: 22, presented: presentedEcdsa) == .unknown)
}

@Test func knownHostsPersistIsIdempotentForDuplicates() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let appDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("sshkit-dup-\(UUID().uuidString)")
    let appPath = (appDir as NSString).appendingPathComponent("trusted.json")
    let khPath = try tempFile("")
    defer {
        try? FileManager.default.removeItem(atPath: appDir)
        try? FileManager.default.removeItem(atPath: khPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let candidate = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)
    store.persist(host: "dup.example.com", port: 22, candidate: candidate)
    store.persist(host: "dup.example.com", port: 22, candidate: candidate)

    // Only one record should be on disk despite two persists.
    let data = try Data(contentsOf: URL(fileURLWithPath: appPath))
    let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    #expect(json?.count == 1)
    #expect(store.evaluate(host: "dup.example.com", port: 22, presented: candidate) == .trusted)
}

@Test func knownHostsAppStoreTakesPriorityAndPortDistinguishes() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let appDir = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("sshkit-prio-\(UUID().uuidString)")
    let appPath = (appDir as NSString).appendingPathComponent("trusted.json")
    let khPath = try tempFile("")
    defer {
        try? FileManager.default.removeItem(atPath: appDir)
        try? FileManager.default.removeItem(atPath: khPath)
    }

    let store = KnownHostsStore(appStorePath: appPath, systemKnownHosts: khPath)
    let candidate = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)
    store.persist(host: "ported.example.com", port: 2022, candidate: candidate)

    #expect(store.evaluate(host: "ported.example.com", port: 2022, presented: candidate) == .trusted)
    // A different port for the same host/key is unknown.
    #expect(store.evaluate(host: "ported.example.com", port: 22, presented: candidate) == .unknown)
}

@Test func hostKeyCandidateInvalidBase64FingerprintFallback() {
    // Not valid base64: fingerprint computation returns the bare "SHA256:" prefix.
    let candidate = HostKeyCandidate(keyType: "ssh-ed25519", base64: "!!!not base64!!!")
    #expect(candidate.fingerprintSHA256 == "SHA256:")
}

@Test func hostKeyCandidateCodableRecomputesDerivedFields() throws {
    let pub = "AAAAC3NzaC1lZDI1NTE5AAAAIFR3OdStNkl4oJzrg2zguLPFegCHdqMTg1NQ3Ye2NQ2L"
    let original = HostKeyCandidate(keyType: "ssh-ed25519", base64: pub)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(HostKeyCandidate.self, from: encoded)
    #expect(decoded == original)
    #expect(decoded.fingerprintSHA256 == original.fingerprintSHA256)
    #expect(decoded.openSSHString == original.openSSHString)

    // Decoding ignores stored derived fields and recomputes from keyType/base64.
    let tampered = """
    {"keyType":"ssh-ed25519","base64":"\(pub)","openSSHString":"WRONG","fingerprintSHA256":"SHA256:WRONG"}
    """
    let decodedTampered = try JSONDecoder().decode(
        HostKeyCandidate.self, from: Data(tampered.utf8)
    )
    #expect(decodedTampered.openSSHString == original.openSSHString)
    #expect(decodedTampered.fingerprintSHA256 == original.fingerprintSHA256)
}

// MARK: - KeyLoader real-key paths

@Test func keyLoaderLoadsPlainEd25519Key() throws {
    let keyPath = try #require(generateKey(type: "ed25519", passphrase: ""))
    defer { removeKey(keyPath) }

    let loaded = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: nil)
    guard case .ed25519 = loaded else {
        Issue.record("expected .ed25519, got \(loaded)")
        return
    }
    // The auth method builds without throwing for a username.
    _ = loaded.authMethod(username: "tester")
}

@Test func keyLoaderLoadsPlainRSAKey() throws {
    let keyPath = try #require(generateKey(type: "rsa", passphrase: "", bits: 2048))
    defer { removeKey(keyPath) }

    let loaded = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: nil)
    guard case .rsa = loaded else {
        Issue.record("expected .rsa, got \(loaded)")
        return
    }
    _ = loaded.authMethod(username: "tester")
}

@Test func keyLoaderEncryptedKeyWithoutPassphraseNeedsPassphrase() throws {
    let keyPath = try #require(generateKey(type: "ed25519", passphrase: "topsecret"))
    defer { removeKey(keyPath) }

    do {
        _ = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: nil)
        Issue.record("expected an error for encrypted key without passphrase")
    } catch let error as SSHKeyError {
        guard case .needsPassphrase = error else {
            Issue.record("expected .needsPassphrase, got \(error)")
            return
        }
    }
}

@Test func keyLoaderEncryptedKeyWithCorrectPassphraseLoads() throws {
    let keyPath = try #require(generateKey(type: "ed25519", passphrase: "topsecret"))
    defer { removeKey(keyPath) }

    let loaded = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: "topsecret")
    guard case .ed25519 = loaded else {
        Issue.record("expected .ed25519, got \(loaded)")
        return
    }
}

@Test func keyLoaderEncryptedKeyWithWrongPassphraseReportsWrongPassphrase() throws {
    let keyPath = try #require(generateKey(type: "ed25519", passphrase: "topsecret"))
    defer { removeKey(keyPath) }

    do {
        _ = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: "wrong")
        Issue.record("expected an error for wrong passphrase")
    } catch let error as SSHKeyError {
        guard case .wrongPassphrase = error else {
            Issue.record("expected .wrongPassphrase, got \(error)")
            return
        }
    }
}

@Test func keyLoaderEncryptedRSAWithCorrectPassphraseLoads() throws {
    let keyPath = try #require(generateKey(type: "rsa", passphrase: "rsapass", bits: 2048))
    defer { removeKey(keyPath) }

    let loaded = try SSHKeyLoader.load(contentsOf: keyPath, passphrase: "rsapass")
    guard case .rsa = loaded else {
        Issue.record("expected .rsa, got \(loaded)")
        return
    }
}

@Test func keyLoaderDefaultKeyCandidatesReturnsOnlyExistingPaths() {
    // Pure call: every returned path must exist and be under ~/.ssh.
    let candidates = SSHKeyLoader.defaultKeyCandidates()
    for path in candidates {
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.contains("/.ssh/"))
    }
}

// MARK: - HostFileEntry value semantics

@Test func hostFileEntryIdentifiableAndHashable() {
    let entry = HostFileEntry(name: "file.txt", size: 42, isDirectory: false, isSymlink: false)
    #expect(entry.id == "file.txt")
    let dir = HostFileEntry(name: "dir", size: 0, isDirectory: true, isSymlink: false)
    let set: Set<HostFileEntry> = [entry, dir, entry]
    #expect(set.count == 2)
}
