import Foundation

/// A registry the apple/container CLI holds a login for (in the keychain
/// under `com.apple.container.registry`), from `container registry list`.
public struct AppleRegistryLogin: Sendable, Equatable, Identifiable, Codable {
    public var hostname: String
    public var username: String
    public var created: Date?
    public var modified: Date?

    public var id: String { hostname }

    public init(hostname: String, username: String, created: Date? = nil, modified: Date? = nil) {
        self.hostname = hostname
        self.username = username
        self.created = created
        self.modified = modified
    }
}

/// The scheme `container registry login --scheme` uses to reach a registry.
public enum AppleRegistryScheme: String, Sendable, CaseIterable {
    case https
    case http
}

extension AppleContainerControl {
    // MARK: - Registry logins

    public static func listRegistryLogins(cliOverride: String? = nil) async throws -> [AppleRegistryLogin] {
        let output = try await runContainer(["registry", "list", "--format", "json"], cliOverride: cliOverride)
        return parseRegistryLogins(output)
    }

    /// Logs in to `server`. The password goes to the CLI on stdin
    /// (`--password-stdin`); it is never put on argv, logged or stored by
    /// Gantry. The CLI checks the credentials against the registry and saves
    /// them in the keychain.
    public static func loginRegistry(
        server: String,
        username: String,
        password: String,
        scheme: AppleRegistryScheme = .https,
        cliOverride: String? = nil
    ) async throws {
        let arguments = try registryLoginArguments(server: server, username: username, scheme: scheme)
        guard !password.isEmpty else { throw AppleSystemError.invalidInput("Enter a password or access token.") }
        _ = try await runContainer(arguments, cliOverride: cliOverride, input: Data(password.utf8))
    }

    public static func logoutRegistry(_ server: String, cliOverride: String? = nil) async throws {
        let host = server.trimmingCharacters(in: .whitespaces)
        guard isValidRegistryServer(host) else {
            throw AppleSystemError.invalidInput("“\(server)” is not a valid registry host name.")
        }
        _ = try await runContainer(["registry", "logout", host], cliOverride: cliOverride)
    }

    /// The `registry login` arguments. They never contain the password.
    static func registryLoginArguments(
        server: String,
        username: String,
        scheme: AppleRegistryScheme
    ) throws -> [String] {
        let host = server.trimmingCharacters(in: .whitespaces)
        let user = username.trimmingCharacters(in: .whitespaces)
        guard isValidRegistryServer(host) else {
            throw AppleSystemError.invalidInput("“\(server)” is not a valid registry host name. Use a host name with an optional port, for example ghcr.io or localhost:5000.")
        }
        guard !user.isEmpty else { throw AppleSystemError.invalidInput("Enter a user name.") }
        var arguments = ["registry", "login", "--username", user, "--password-stdin"]
        if scheme != .https { arguments += ["--scheme", scheme.rawValue] }
        arguments.append(host)
        return arguments
    }

    /// A registry host as apple/container accepts it: a DNS name or a bracketed
    /// IPv6 address, with an optional port (`docker.io`, `localhost:5000`,
    /// `[::1]:5000`).
    public static func isValidRegistryServer(_ name: String) -> Bool {
        name.wholeMatch(of: /((?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])(?:\.(?:[a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9]))*|\[[a-fA-F0-9:]+\])(:[0-9]+)?/) != nil
    }

    static func parseRegistryLogins(_ json: String) -> [AppleRegistryLogin] {
        guard let objects = jsonObject(json) as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let host = (object["name"] as? String) ?? (object["hostname"] as? String) ?? (object["id"] as? String) else {
                return nil
            }
            return AppleRegistryLogin(
                hostname: host,
                username: (object["username"] as? String) ?? "",
                created: date(object["creationDate"] ?? object["createdDate"]),
                modified: date(object["modificationDate"] ?? object["modifiedDate"])
            )
        }
        .sorted { $0.hostname < $1.hostname }
    }

    /// A date as Swift's JSONEncoder writes it: seconds since 2001 by default,
    /// or an ISO 8601 string.
    static func date(_ any: Any?) -> Date? {
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        guard let string = any as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
