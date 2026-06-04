import Foundation
import Crypto

/// A host key presented (or stored) for a host, with its SHA256 fingerprint.
public struct HostKeyCandidate: Sendable, Codable, Equatable {
    /// The key algorithm, e.g. "ssh-ed25519" or "ssh-rsa".
    public let keyType: String
    /// Base64-encoded raw key blob (no algorithm prefix).
    public let base64: String
    /// "type base64" — the OpenSSH public key line form.
    public let openSSHString: String
    /// "SHA256:" + base64(SHA256(rawKeyBlob)) without trailing '=' padding.
    public let fingerprintSHA256: String

    public init(keyType: String, base64: String) {
        self.keyType = keyType
        self.base64 = base64
        self.openSSHString = keyType + " " + base64
        self.fingerprintSHA256 = HostKeyCandidate.fingerprint(forBase64Blob: base64)
    }

    enum CodingKeys: String, CodingKey {
        case keyType
        case base64
        case openSSHString
        case fingerprintSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyType = try container.decode(String.self, forKey: .keyType)
        let base64 = try container.decode(String.self, forKey: .base64)
        // Recompute derived fields to stay consistent regardless of stored values.
        self.init(keyType: keyType, base64: base64)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyType, forKey: .keyType)
        try container.encode(base64, forKey: .base64)
        try container.encode(openSSHString, forKey: .openSSHString)
        try container.encode(fingerprintSHA256, forKey: .fingerprintSHA256)
    }

    /// Computes the OpenSSH-style SHA256 fingerprint from a base64 key blob.
    static func fingerprint(forBase64Blob base64: String) -> String {
        guard let blob = Data(base64Encoded: base64) else {
            return "SHA256:"
        }
        let digest = SHA256.hash(data: blob)
        let encoded = Data(digest).base64EncodedString()
        let trimmed = encoded.hasSuffix("=")
            ? String(encoded.prefix(while: { $0 != "=" }))
            : encoded
        return "SHA256:" + trimmed
    }
}

/// The outcome of evaluating a presented host key against trust stores.
public enum KnownHostsVerdict: Sendable, Equatable {
    case trusted
    case unknown
    case mismatch(expected: String)
}

/// A persisted trusted-host record in the app store.
private struct TrustedHostRecord: Codable, Sendable {
    let host: String
    let port: Int
    let candidate: HostKeyCandidate
}

/// Thread-safe store evaluating host keys against an app-managed JSON store
/// first, then the system known_hosts file. Callable from any context.
public final class KnownHostsStore: @unchecked Sendable {
    private let appStorePath: String
    private let systemKnownHosts: String
    private let lock = NSLock()

    public init(
        appStorePath: String = NSHomeDirectory() + "/Library/Application Support/Gantry/trusted_hosts.json",
        systemKnownHosts: String = NSHomeDirectory() + "/.ssh/known_hosts"
    ) {
        self.appStorePath = (appStorePath as NSString).expandingTildeInPath
        self.systemKnownHosts = (systemKnownHosts as NSString).expandingTildeInPath
    }

    /// Evaluates a presented key for a host/port. Checks the app store first,
    /// then the system known_hosts. A matching key type with a different blob
    /// yields `.mismatch`; no entry yields `.unknown`.
    public func evaluate(host: String, port: Int, presented: HostKeyCandidate) -> KnownHostsVerdict {
        let stored = collectStoredCandidates(host: host, port: port)

        if stored.isEmpty {
            return .unknown
        }

        // Exact match (same type + blob) anywhere => trusted.
        if stored.contains(where: { $0.keyType == presented.keyType && $0.base64 == presented.base64 }) {
            return .trusted
        }

        // Same algorithm but different blob => mismatch (potential MITM).
        if let conflicting = stored.first(where: { $0.keyType == presented.keyType }) {
            return .mismatch(expected: conflicting.fingerprintSHA256)
        }

        // We know this host but only under other algorithms. Treat as unknown
        // so the user can decide to trust this new algorithm's key.
        return .unknown
    }

    /// Appends a trusted candidate to the app JSON store atomically.
    public func persist(host: String, port: Int, candidate: HostKeyCandidate) {
        lock.lock()
        defer { lock.unlock() }

        var records = readAppRecordsLocked()
        let isDuplicate = records.contains {
            $0.host == host && $0.port == port
                && $0.candidate.keyType == candidate.keyType
                && $0.candidate.base64 == candidate.base64
        }
        guard !isDuplicate else { return }

        records.append(TrustedHostRecord(host: host, port: port, candidate: candidate))

        let directory = (appStorePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: appStorePath), options: .atomic)
    }

    // MARK: - Internals

    private func collectStoredCandidates(host: String, port: Int) -> [HostKeyCandidate] {
        lock.lock()
        let appRecords = readAppRecordsLocked()
        lock.unlock()

        var result: [HostKeyCandidate] = appRecords
            .filter { $0.host == host && $0.port == port }
            .map(\.candidate)

        result.append(contentsOf: parseSystemKnownHosts(host: host, port: port))
        return result
    }

    /// Must be called with `lock` held.
    private func readAppRecordsLocked() -> [TrustedHostRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appStorePath)) else {
            return []
        }
        return (try? JSONDecoder().decode([TrustedHostRecord].self, from: data)) ?? []
    }

    /// Parses system known_hosts lines matching the host/port. Supports plain
    /// "host[,host2] type base64" and bracketed "[host]:port type base64".
    /// Skips hashed (|1|), @cert-authority, @revoked and comment lines.
    private func parseSystemKnownHosts(host: String, port: Int) -> [HostKeyCandidate] {
        guard let contents = try? String(contentsOfFile: systemKnownHosts, encoding: .utf8) else {
            return []
        }

        var result: [HostKeyCandidate] = []

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Skip marker-prefixed lines (@cert-authority, @revoked).
            if line.hasPrefix("@") { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3 else { continue }

            let hostsField = fields[0]
            // Skip hashed host entries.
            if hostsField.hasPrefix("|1|") { continue }

            let keyType = fields[1]
            let base64 = fields[2]

            let patterns = hostsField.split(separator: ",").map(String.init)
            if patterns.contains(where: { hostPattern($0, matchesHost: host, port: port) }) {
                result.append(HostKeyCandidate(keyType: keyType, base64: base64))
            }
        }

        return result
    }

    /// Matches a single known_hosts host token against a host/port. Handles the
    /// "[host]:port" bracket form for non-default ports; bare tokens match the
    /// default port 22.
    private func hostPattern(_ token: String, matchesHost host: String, port: Int) -> Bool {
        if token.hasPrefix("[") {
            // Form: [host]:port
            guard let closeBracket = token.firstIndex(of: "]") else { return false }
            let bracketHost = String(token[token.index(after: token.startIndex)..<closeBracket])
            let afterBracket = token[token.index(after: closeBracket)...]
            guard afterBracket.hasPrefix(":") else { return false }
            let portString = afterBracket.dropFirst()
            guard let tokenPort = Int(portString) else { return false }
            return bracketHost == host && tokenPort == port
        } else {
            // Bare host token implies the default SSH port.
            return token == host && port == 22
        }
    }
}
