import Foundation
import DockerKit

/// Resolves registry credentials the way the `docker` CLI would: by reading
/// `~/.docker/config.json` and, when an entry delegates to a credential helper
/// (`credsStore` / `credHelpers`), invoking `docker-credential-<helper> get`.
///
/// Gantry speaks the Docker Engine API directly, so — unlike the CLI — nothing
/// injects `X-Registry-Auth` for us. We play the client and resolve the token
/// ourselves before a pull. Apple/container hosts are out of scope: their pulls
/// run through the `container` CLI, which does its own auth.
public struct RegistryCredentialStore: Sendable {
    /// A credential as returned by a `docker-credential-*` helper's `get`.
    public struct HelperCredential: Sendable, Equatable {
        public var username: String
        public var secret: String
        public init(username: String, secret: String) {
            self.username = username
            self.secret = secret
        }
    }

    private let configURL: URL
    private let helperRunner: @Sendable (_ helper: String, _ serverURL: String) async -> HelperCredential?

    public init(configURL: URL? = nil) {
        self.configURL = configURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".docker", isDirectory: true)
            .appendingPathComponent("config.json")
        self.helperRunner = { helper, server in
            await RegistryCredentialStore.runHelper(helper, serverURL: server)
        }
    }

    /// Test seam: inject a fake helper so resolution can be exercised without
    /// spawning `docker-credential-*` processes.
    init(
        configURL: URL,
        helperRunner: @escaping @Sendable (String, String) async -> HelperCredential?
    ) {
        self.configURL = configURL
        self.helperRunner = helperRunner
    }

    // MARK: - Resolution

    /// Resolves credentials for the registry that hosts `reference`, mirroring
    /// how the `docker` CLI reads `~/.docker/config.json`. Returns nil when no
    /// credentials apply (anonymous pull) or the config is absent/unreadable.
    public func auth(forImageReference reference: String) async -> RegistryAuth? {
        guard let config = await loadConfig() else { return nil }
        let domain = Self.registryDomain(forImageReference: reference)
        let server = Self.serverAddress(forDomain: domain)
        let keys = Self.lookupKeys(forDomain: domain)

        // 1. A per-registry helper takes priority over everything else.
        if let helper = Self.firstValue(in: config.credHelpers, keys: keys) {
            return await helperAuth(helper, server: server)
        }
        // 2. An inline auths entry: identity token or base64 username:password.
        if let entry = Self.firstValue(in: config.auths, keys: keys) {
            if let token = entry.identityToken, !token.isEmpty {
                return RegistryAuth(serverAddress: server, identityToken: token)
            }
            if let basic = entry.auth, let creds = Self.decodeBasic(basic) {
                return RegistryAuth(
                    username: creds.user,
                    password: creds.password,
                    serverAddress: server
                )
            }
            // Entry present but empty -> fall through to the global store.
        }
        // 3. The global credential store (e.g. osxkeychain).
        if let store = config.credsStore {
            return await helperAuth(store, server: server)
        }
        return nil
    }

    private func helperAuth(_ helper: String, server: String) async -> RegistryAuth? {
        guard let cred = await helperRunner(helper, server), !cred.secret.isEmpty else {
            return nil
        }
        // Helpers signal an identity token by returning the username `<token>`.
        if cred.username == "<token>" {
            return RegistryAuth(serverAddress: server, identityToken: cred.secret)
        }
        return RegistryAuth(username: cred.username, password: cred.secret, serverAddress: server)
    }

    // MARK: - Config file

    struct ConfigFile: Sendable {
        var auths: [String: AuthEntry] = [:]
        var credsStore: String?
        var credHelpers: [String: String] = [:]
    }

    struct AuthEntry: Sendable {
        var auth: String?
        var identityToken: String?
    }

    private func loadConfig() async -> ConfigFile? {
        let url = configURL
        return await Task.detached(priority: .userInitiated) {
            Self.parseConfig(at: url)
        }.value
    }

    static func parseConfig(at url: URL) -> ConfigFile? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var config = ConfigFile()
        if let auths = root["auths"] as? [String: Any] {
            for (key, value) in auths {
                let dict = value as? [String: Any]
                config.auths[key] = AuthEntry(
                    auth: dict?["auth"] as? String,
                    identityToken: dict?["identitytoken"] as? String
                )
            }
        }
        config.credsStore = root["credsStore"] as? String
        if let helpers = root["credHelpers"] as? [String: String] {
            config.credHelpers = helpers
        }
        return config
    }

    // MARK: - Pure helpers

    /// The registry domain that hosts an image reference, applying Docker's
    /// official-image rule: a first path segment is only a registry when it
    /// looks like a host (contains `.` or `:`) or is `localhost`; otherwise the
    /// reference names a Docker Hub image.
    static func registryDomain(forImageReference reference: String) -> String {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard let slash = ref.firstIndex(of: "/") else { return "docker.io" }
        let prefix = String(ref[..<slash])
        if prefix == "localhost" || prefix.contains(".") || prefix.contains(":") {
            return prefix
        }
        return "docker.io"
    }

    /// The `serveraddress` carried in the auth header and handed to a credential
    /// helper's `get`. Docker Hub uses its historical v1 index URL.
    static func serverAddress(forDomain domain: String) -> String {
        domain == "docker.io" ? "https://index.docker.io/v1/" : domain
    }

    /// Config keys to try for a domain, widest-compatible first. Docker Hub is
    /// stored under several historical aliases.
    static func lookupKeys(forDomain domain: String) -> [String] {
        if domain == "docker.io" {
            return [
                "https://index.docker.io/v1/",
                "index.docker.io",
                "docker.io",
                "registry-1.docker.io"
            ]
        }
        return [domain, "https://\(domain)", "http://\(domain)", "https://\(domain)/v1/"]
    }

    static func firstValue<V>(in dict: [String: V], keys: [String]) -> V? {
        for key in keys where dict[key] != nil { return dict[key] }
        return nil
    }

    /// Decodes a base64 `username:password` from an `auths` entry's `auth`. The
    /// password may itself contain colons, so only the first is a separator.
    static func decodeBasic(_ value: String) -> (user: String, password: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":")
        else { return nil }
        return (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
    }

    // MARK: - Credential helper subprocess

    static func runHelper(_ helper: String, serverURL: String) async -> HelperCredential? {
        guard let binary = helperBinary(named: helper) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            runHelperSync(binary: binary, serverURL: serverURL)
        }.value
    }

    /// Locates `docker-credential-<helper>` across common install dirs and PATH.
    static func helperBinary(named helper: String) -> String? {
        let name = "docker-credential-\(helper)"
        var dirs = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/Applications/Docker.app/Contents/Resources/bin"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        let fm = FileManager.default
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func runHelperSync(binary: String, serverURL: String) -> HelperCredential? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["get"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // The helper reads the server URL on stdin, then emits a JSON credential.
        stdin.fileHandleForWriting.write(Data((serverURL + "\n").utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let secret = obj["Secret"] as? String, !secret.isEmpty
        else { return nil }
        let username = (obj["Username"] as? String) ?? ""
        return HelperCredential(username: username, secret: secret)
    }
}
