import Foundation
import DockerKit

/// The `status` of an ExecCredential that a credential plugin prints.
public struct KubeExecCredential: Hashable, Sendable, CustomStringConvertible {
    public var token: String?
    public var clientCertificatePEM: Data?
    public var clientKeyPEM: Data?
    public var expiration: Date?

    public init(token: String? = nil, clientCertificatePEM: Data? = nil, clientKeyPEM: Data? = nil, expiration: Date? = nil) {
        self.token = token
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.expiration = expiration
    }

    public var description: String {
        "KubeExecCredential(token: \(token == nil ? "no" : "yes"), certificate: \(clientCertificatePEM == nil ? "no" : "yes"))"
    }

    /// True when the credential is still good at `date`, with a margin.
    public func isValid(at date: Date = Date()) -> Bool {
        guard let expiration else { return true }
        return expiration.timeIntervalSince(date) > 30
    }

    /// Parses the plugin output (client.authentication.k8s.io v1 or v1beta1).
    public static func parse(_ data: Data) throws -> KubeExecCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["kind"] as? String == "ExecCredential",
              let status = root["status"] as? [String: Any] else {
            throw KubeAPIError.credentials(String(localized: "The credential plugin returned output that Gantry cannot read.", bundle: .module))
        }
        let credential = KubeExecCredential(
            token: (status["token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            clientCertificatePEM: (status["clientCertificateData"] as? String).map { Data($0.utf8) },
            clientKeyPEM: (status["clientKeyData"] as? String).map { Data($0.utf8) },
            expiration: KubeResourceParser.date(status["expirationTimestamp"])
        )
        if credential.token == nil, credential.clientCertificatePEM == nil || credential.clientKeyPEM == nil {
            throw KubeAPIError.credentials(String(localized: "The credential plugin returned no token and no certificate.", bundle: .module))
        }
        return credential
    }

    /// The `KUBERNETES_EXEC_INFO` value for the plugin. It never holds a secret.
    public static func execInfo(_ config: KubeExecConfig, connection: KubeConnection) -> String {
        var spec: [String: Any] = ["interactive": false]
        if config.provideClusterInfo {
            var cluster: [String: Any] = ["server": connection.server.absoluteString]
            if let ca = connection.certificateAuthorityPEM { cluster["certificate-authority-data"] = ca.base64EncodedString() }
            if connection.insecureSkipTLSVerify { cluster["insecure-skip-tls-verify"] = true }
            if let name = connection.tlsServerName { cluster["tls-server-name"] = name }
            spec["cluster"] = cluster
        }
        let info: [String: Any] = ["apiVersion": config.apiVersion, "kind": "ExecCredential", "spec": spec]
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The plugin path: absolute, relative to the kubeconfig, or found in
    /// PATH plus the Homebrew directories (an app started from Finder has
    /// a short PATH).
    public static func resolveCommand(
        _ config: KubeExecConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let command = config.command
        if command.hasPrefix("/") { return isExecutable(command) ? command : nil }
        if command.contains("/") {
            let path = ((config.baseDirectory as NSString).appendingPathComponent(command) as NSString).standardizingPath
            return isExecutable(path) ? path : nil
        }
        return searchPath(environment).map { ($0 as NSString).appendingPathComponent(command) }.first(where: isExecutable)
    }

    static func searchPath(_ environment: [String: String]) -> [String] {
        var result: [String] = []
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for entry in current + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !entry.isEmpty && !result.contains(entry) {
            result.append(entry)
        }
        return result
    }

    /// Runs the plugin and parses its output. Its stderr goes into the error
    /// text with the env values masked; the plugin output is never logged.
    public static func run(
        _ config: KubeExecConfig,
        connection: KubeConnection,
        runner: any KubeProcessRunner = KubeChildProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) async throws -> KubeExecCredential {
        guard let path = resolveCommand(config, environment: environment, isExecutable: isExecutable) else {
            throw KubeAPIError.credentials(String(localized: "The credential plugin \(config.command) is not installed.", bundle: .module))
        }
        var pluginEnvironment = config.env
        pluginEnvironment["KUBERNETES_EXEC_INFO"] = execInfo(config, connection: connection)
        pluginEnvironment["PATH"] = searchPath(environment).joined(separator: ":")
        let result = try await runner.run(path, config.args, environment: pluginEnvironment)
        guard result.succeeded else {
            let text = KubeRedaction.redact(
                String(decoding: result.stderr.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                secrets: Array(config.env.values)
            )
            let summary = result.summary
            throw KubeAPIError.credentials(text.isEmpty
                ? String(localized: "The credential plugin failed (\(summary)).", bundle: .module)
                : text)
        }
        return try parse(result.stdout)
    }
}

/// The result of a finished process.
public struct KubeProcessResult: Sendable {
    public var succeeded: Bool
    /// The exit status or signal, for messages.
    public var summary: String
    public var stdout: Data
    public var stderr: Data

    public init(succeeded: Bool, summary: String, stdout: Data, stderr: Data) {
        self.succeeded = succeeded
        self.summary = summary
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a credential plugin. Tests give a fake, so they start no process.
public protocol KubeProcessRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> KubeProcessResult
}

public struct KubeChildProcessRunner: KubeProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> KubeProcessResult {
        let result = try await ChildProcess.run(executable, arguments, environment: environment)
        return KubeProcessResult(succeeded: result.exit.succeeded, summary: result.exit.summary, stdout: result.stdout, stderr: result.stderr)
    }
}

/// Keeps exec plugin credentials in memory until they expire. Nothing goes
/// to disk.
actor KubeCredentialCache {
    static let shared = KubeCredentialCache()

    private var entries: [KubeExecConfig: KubeExecCredential] = [:]
    private var running: [KubeExecConfig: Task<KubeExecCredential, Error>] = [:]

    func credential(for config: KubeExecConfig, connection: KubeConnection, refresh: Bool = false) async throws -> KubeExecCredential {
        if !refresh, let cached = entries[config], cached.isValid() { return cached }
        if let task = running[config] { return try await task.value }
        let task = Task { try await KubeExecCredential.run(config, connection: connection) }
        running[config] = task
        defer { running[config] = nil }
        let credential = try await task.value
        entries[config] = credential
        return credential
    }

    func invalidate(_ config: KubeExecConfig) {
        entries[config] = nil
    }
}
