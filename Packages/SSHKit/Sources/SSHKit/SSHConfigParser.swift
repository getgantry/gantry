import Foundation

/// A single `Host` block from an ssh_config file.
public struct SSHConfigEntry: Sendable {
    /// Host alias patterns, e.g. ["prod-*", "db1"].
    public var patterns: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String]

    public init(
        patterns: [String],
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFiles: [String] = []
    ) {
        self.patterns = patterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
    }
}

/// The result of resolving a host alias against an ssh_config file.
public struct ResolvedSSHConfig: Sendable {
    public var hostName: String
    public var user: String?
    public var port: Int
    public var identityFiles: [String]

    public init(hostName: String, user: String?, port: Int, identityFiles: [String]) {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
    }
}

/// Parses ~/.ssh/config with OpenSSH first-obtained-value-wins semantics.
public enum SSHConfig {
    /// All concrete host aliases from the config, in file order — wildcard
    /// patterns (`*`, `?`) and negations are skipped. Used by the add-host UI
    /// to offer one-click import.
    public static func listHosts(configPath: String = "~/.ssh/config") -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for entry in parse(configPath: configPath) {
            for pattern in entry.patterns
            where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                if seen.insert(pattern).inserted {
                    hosts.append(pattern)
                }
            }
        }
        return hosts
    }

    /// Resolves a host alias. On a missing or unreadable config file, returns
    /// defaults (hostName == host, port == 22).
    public static func resolve(host: String, configPath: String = "~/.ssh/config") -> ResolvedSSHConfig {
        let entries = parse(configPath: configPath)

        var hostName: String?
        var user: String?
        var port: Int?
        var identityFiles: [String] = []

        // OpenSSH: the first matching value for each keyword wins. Walk entries
        // top to bottom and only fill values we have not seen yet.
        for entry in entries where entry.patterns.contains(where: { matches(pattern: $0, host: host) }) {
            if hostName == nil { hostName = entry.hostName }
            if user == nil { user = entry.user }
            if port == nil { port = entry.port }
            // IdentityFile is additive in OpenSSH; preserve order, dedupe.
            for file in entry.identityFiles where !identityFiles.contains(file) {
                identityFiles.append(file)
            }
        }

        let resolvedIdentityFiles = identityFiles.map { (($0 as NSString).expandingTildeInPath) }

        return ResolvedSSHConfig(
            hostName: hostName ?? host,
            user: user,
            port: port ?? 22,
            identityFiles: resolvedIdentityFiles
        )
    }

    /// Parses the config file into ordered host blocks.
    static func parse(configPath: String) -> [SSHConfigEntry] {
        let expanded = (configPath as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return []
        }

        var entries: [SSHConfigEntry] = []
        var current: SSHConfigEntry?

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Keyword/value may be separated by '=' or whitespace.
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                line = key + " " + value
            }

            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            switch keyword {
            case "host":
                if let entry = current { entries.append(entry) }
                let patterns = value
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map(String.init)
                current = SSHConfigEntry(patterns: patterns)
            case "hostname":
                current?.hostName = unquote(value)
            case "user":
                current?.user = unquote(value)
            case "port":
                current?.port = Int(value)
            case "identityfile":
                current?.identityFiles.append(unquote(value))
            default:
                break
            }
        }

        if let entry = current { entries.append(entry) }
        return entries
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    /// Matches an OpenSSH host pattern (supporting `*` and `?` globs and a
    /// leading `!` negation) against a host string. Negated patterns return
    /// false so they neither match nor are treated as positive matches.
    static func matches(pattern: String, host: String) -> Bool {
        if pattern.hasPrefix("!") {
            return false
        }
        return fnmatch(pattern, host, 0) == 0
    }
}
