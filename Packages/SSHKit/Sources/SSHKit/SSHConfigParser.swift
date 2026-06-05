import Foundation

/// A single `Host` block from an ssh_config file.
public struct SSHConfigEntry: Sendable {
    /// Host alias patterns, e.g. ["prod-*", "db1"].
    public var patterns: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String]
    /// Raw `ProxyJump` value: comma-separated `[user@]host[:port]` specs or
    /// aliases, or "none".
    public var proxyJump: String?

    public init(
        patterns: [String],
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFiles: [String] = [],
        proxyJump: String? = nil
    ) {
        self.patterns = patterns
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
    }
}

/// The result of resolving a host alias against an ssh_config file.
public struct ResolvedSSHConfig: Sendable {
    public var hostName: String
    public var user: String?
    public var port: Int
    public var identityFiles: [String]
    /// The `ProxyJump` chain to reach this host, outermost hop first. Each
    /// hop is itself fully resolved (alias → HostName/User/Port/keys).
    public var jumps: [ResolvedSSHConfig]

    public init(
        hostName: String,
        user: String?,
        port: Int,
        identityFiles: [String],
        jumps: [ResolvedSSHConfig] = []
    ) {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.jumps = jumps
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
    /// defaults (hostName == host, port == 22). `ProxyJump` chains are
    /// resolved recursively into `jumps`, outermost hop first.
    public static func resolve(host: String, configPath: String = "~/.ssh/config") -> ResolvedSSHConfig {
        resolve(host: host, configPath: configPath, visited: [])
    }

    private static func resolve(
        host: String,
        configPath: String,
        visited: Set<String>
    ) -> ResolvedSSHConfig {
        let entries = parse(configPath: configPath)

        var hostName: String?
        var user: String?
        var port: Int?
        var identityFiles: [String] = []
        var proxyJump: String?

        // OpenSSH: the first matching value for each keyword wins. Walk entries
        // top to bottom and only fill values we have not seen yet.
        for entry in entries where entry.patterns.contains(where: { matches(pattern: $0, host: host) }) {
            if hostName == nil { hostName = entry.hostName }
            if user == nil { user = entry.user }
            if port == nil { port = entry.port }
            if proxyJump == nil { proxyJump = entry.proxyJump }
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
            identityFiles: resolvedIdentityFiles,
            jumps: resolveJumps(
                proxyJump: proxyJump,
                configPath: configPath,
                visited: visited.union([host])
            )
        )
    }

    /// Expands a `ProxyJump` value into resolved hops, outermost first.
    /// Each spec is `[user@]host[:port]`; `host` may itself be a config alias
    /// whose own `ProxyJump` is prepended recursively (cycle-guarded).
    private static func resolveJumps(
        proxyJump: String?,
        configPath: String,
        visited: Set<String>
    ) -> [ResolvedSSHConfig] {
        guard let proxyJump, proxyJump.lowercased() != "none", visited.count <= 8 else { return [] }

        var hops: [ResolvedSSHConfig] = []
        for spec in proxyJump.split(separator: ",") {
            let spec = spec.trimmingCharacters(in: .whitespaces)
            guard !spec.isEmpty else { continue }

            // [user@]host[:port] — the user/port given inline beat the alias's.
            var rest = spec
            var inlineUser: String?
            if let at = rest.firstIndex(of: "@") {
                inlineUser = String(rest[..<at])
                rest = String(rest[rest.index(after: at)...])
            }
            var inlinePort: Int?
            // IPv6 literals come bracketed ([::1]:2222); a bare colon means port.
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let hostPart = String(rest[rest.index(after: rest.startIndex)..<close])
                let after = rest[rest.index(after: close)...]
                if after.hasPrefix(":") { inlinePort = Int(after.dropFirst()) }
                rest = hostPart
            } else if let colon = rest.lastIndex(of: ":"), rest.firstIndex(of: ":") == colon {
                inlinePort = Int(rest[rest.index(after: colon)...])
                rest = String(rest[..<colon])
            }

            guard !visited.contains(rest) else { continue }
            var hop = resolve(host: rest, configPath: configPath, visited: visited)
            if let inlineUser { hop.user = inlineUser }
            if let inlinePort { hop.port = inlinePort }
            // A hop's own jumps come before the hop itself.
            hops.append(contentsOf: hop.jumps)
            hop.jumps = []
            hops.append(hop)
        }
        return hops
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
            case "proxyjump":
                current?.proxyJump = unquote(value)
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
