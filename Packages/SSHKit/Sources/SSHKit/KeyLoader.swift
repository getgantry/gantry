import Foundation
import Citadel
import Crypto
import NIOSSH

/// Errors surfaced while loading an SSH private key from disk.
public enum SSHKeyError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case needsPassphrase
    case wrongPassphrase
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "No private key file at \(path)."
        case .unsupportedFormat(let detail):
            "Unsupported key format: \(detail) Only openssh-key-v1 ed25519 and RSA keys are supported (\"-----BEGIN OPENSSH PRIVATE KEY-----\"). Convert with: ssh-keygen -p -f <key>."
        case .needsPassphrase:
            "This key is encrypted and requires a passphrase."
        case .wrongPassphrase:
            "Incorrect passphrase for this key."
        case .parseFailed(let reason):
            "Could not parse the private key: \(reason)"
        }
    }
}

/// A loaded private key, wrapping the concrete Citadel key types behind a
/// `Sendable`-safe enum so callers do not depend on Citadel directly.
public enum LoadedKey: @unchecked Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey)

    /// Builds the Citadel authentication method for this key and a username.
    public func authMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .ed25519(let key):
            .ed25519(username: username, privateKey: key)
        case .rsa(let key):
            .rsa(username: username, privateKey: key)
        }
    }

    /// The raw NIOSSH offer for this key, for delegates that present several
    /// keys over one connection.
    func nioOffer() -> NIOSSHUserAuthenticationOffer.Offer {
        switch self {
        case .ed25519(let key):
            .privateKey(.init(privateKey: .init(ed25519Key: key)))
        case .rsa(let key):
            .privateKey(.init(privateKey: .init(custom: key)))
        }
    }
}

/// Loads OpenSSH private keys from disk and maps low-level Citadel parse
/// failures to a small, user-facing error set.
public enum SSHKeyLoader {
    private static let openSSHMarker = "OPENSSH PRIVATE KEY"

    /// Loads a private key file. Tries ed25519 first, then RSA on type
    /// mismatch. Distinguishes "encrypted, no passphrase given" from "wrong
    /// passphrase" heuristically based on whether a passphrase was supplied.
    public static func load(contentsOf path: String, passphrase: String?) throws -> LoadedKey {
        let expanded = (path as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expanded) else {
            throw SSHKeyError.fileNotFound(expanded)
        }

        let contents: String
        do {
            contents = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw SSHKeyError.parseFailed("could not read file: \(error.localizedDescription)")
        }

        guard contents.contains(Self.openSSHMarker) else {
            let detail: String
            if contents.contains("BEGIN RSA PRIVATE KEY")
                || contents.contains("BEGIN DSA PRIVATE KEY")
                || contents.contains("BEGIN EC PRIVATE KEY")
                || contents.contains("BEGIN PRIVATE KEY") {
                detail = "legacy PEM keys are not supported."
            } else {
                detail = "the file is not an OpenSSH private key."
            }
            throw SSHKeyError.unsupportedFormat(detail)
        }

        let decryptionKey = passphrase.map { Data($0.utf8) }

        // Try ed25519 first.
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: contents, decryptionKey: decryptionKey)
            return .ed25519(key)
        } catch let edError {
            // On a type mismatch (this is an RSA key), try RSA. If that also
            // fails, map whichever error is most informative.
            do {
                let key = try Insecure.RSA.PrivateKey(sshRsa: contents, decryptionKey: decryptionKey)
                return .rsa(key)
            } catch let rsaError {
                throw mapKeyError(edError, rsaError, hasPassphrase: passphrase != nil)
            }
        }
    }

    /// Returns existing default key candidate paths in ~/.ssh, preferring ed25519.
    public static func defaultKeyCandidates() -> [String] {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.ssh/id_ed25519",
            // App-managed identity for setups whose only key is RSA, which
            // the SSH library signs as legacy ssh-rsa (rejected by modern
            // servers).
            home + "/.ssh/gantry_ed25519",
            home + "/.ssh/id_rsa"
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Maps the (ed25519, rsa) attempt errors to a public `SSHKeyError`.
    private static func mapKeyError(_ edError: Error, _ rsaError: Error, hasPassphrase: Bool) -> SSHKeyError {
        // Encrypted key with no decryption key supplied: Citadel throws
        // OpenSSH.KeyError.missingDecryptionKey from the KDF step.
        if isMissingDecryptionKey(edError) || isMissingDecryptionKey(rsaError) {
            return .needsPassphrase
        }

        // A passphrase was provided but decryption produced garbage. The
        // padding/check guards fail in that case.
        if hasPassphrase {
            return .wrongPassphrase
        }

        // Otherwise report the underlying parse failure.
        let reason = describe(edError) + " / " + describe(rsaError)
        return .parseFailed(reason)
    }

    private static func isMissingDecryptionKey(_ error: Error) -> Bool {
        // OpenSSH.KeyError is internal to Citadel; match on its description.
        String(describing: error).contains("missingDecryptionKey")
    }

    private static func describe(_ error: Error) -> String {
        if let invalid = error as? InvalidOpenSSHKey {
            return String(describing: invalid)
        }
        return error.localizedDescription
    }
}
