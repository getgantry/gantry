import Testing
import Foundation
@testable import SSHKit

// Regression tests for getgantry/gantry#25: OpenSSH keys encrypted with
// `ssh-keygen -a N` for N >= 32 bcrypt_pbkdf rounds failed to load. The keys
// are throwaway pairs generated with ssh-keygen at test time.

private let keygen = "/usr/bin/ssh-keygen"
private let passphrase = "testpass"

/// Generates a passphrase-protected key with the given number of KDF rounds
/// in a fresh temp directory. Returns the private key path and the directory.
private func generateKey(type: String, rounds: Int) throws -> (path: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sshkit-rounds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("k").path

    let process = Process()
    process.executableURL = URL(fileURLWithPath: keygen)
    var args = ["-q", "-t", type, "-a", String(rounds), "-N", passphrase, "-C", "", "-f", path]
    if type == "rsa" { args.append(contentsOf: ["-b", "2048"]) }
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return (path, dir)
}

@Suite("KeyLoader bcrypt rounds (#25)")
struct KeyLoaderBcryptRoundsTests {
    @Test("ed25519 key loads with any number of bcrypt rounds", arguments: [16, 31, 32, 64, 100])
    func ed25519(rounds: Int) throws {
        let (path, dir) = try generateKey(type: "ed25519", rounds: rounds)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try SSHKeyLoader.load(contentsOf: path, passphrase: passphrase)
        guard case .ed25519 = key else {
            Issue.record("expected an ed25519 key, got \(key)")
            return
        }
    }

    @Test("RSA key loads with 100 bcrypt rounds")
    func rsa() throws {
        let (path, dir) = try generateKey(type: "rsa", rounds: 100)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try SSHKeyLoader.load(contentsOf: path, passphrase: passphrase)
        guard case .rsa = key else {
            Issue.record("expected an RSA key, got \(key)")
            return
        }
    }

    @Test("a wrong passphrase is still rejected with 100 bcrypt rounds")
    func wrongPassphrase() throws {
        let (path, dir) = try generateKey(type: "ed25519", rounds: 100)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: SSHKeyError.self) {
            _ = try SSHKeyLoader.load(contentsOf: path, passphrase: "not-the-passphrase")
        }
    }
}
