import Foundation

/// The data root ("app root") that Gantry starts the apple/container services
/// with. `container system start` keeps the root only in the launchd plist of
/// the API server; after a reboot or a plain `system start` the CLI falls back
/// to the default folder. So Gantry stores the choice and passes
/// `--app-root` on every start it makes.
public struct AppleDataRoot: Sendable, Equatable, Codable {
    /// The chosen root, or nil for the default folder.
    public var path: String?

    public init(path: String? = nil) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.path = trimmed.isEmpty ? nil : trimmed
    }

    /// `~/Library/Application Support/com.apple.container`.
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.container", isDirectory: true)
            .path
    }

    /// The root that the services use after a start by Gantry.
    public var effectivePath: String { path ?? Self.defaultPath }

    /// True when the root is not the default folder.
    public var isCustom: Bool {
        guard let path else { return false }
        return Self.normalized(path) != Self.normalized(Self.defaultPath)
    }

    /// The arguments of `container system start`.
    public var startArguments: [String] {
        var arguments = ["system", "start", "--disable-kernel-install"]
        if isCustom, let path { arguments += ["--app-root", path] }
        return arguments
    }

    /// Environment for every CLI call: the client side reads
    /// `CONTAINER_APP_ROOT` for the cluster socket and the config copy.
    public var cliEnvironment: [String: String] {
        guard isCustom, let path else { return [:] }
        return ["CONTAINER_APP_ROOT": path]
    }

    /// The shell command that starts the services on this root.
    public var startCommand: String {
        guard isCustom, let path else { return "container system start" }
        return "container system start --app-root \(Self.shellQuoted(path))"
    }

    /// Compares two paths without a trailing slash.
    public static func normalized(_ path: String) -> String {
        var value = (path as NSString).standardizingPath
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Reads and writes the chosen data root in
/// `~/Library/Application Support/Gantry/apple-data-root.json`, so the app,
/// its MCP server and the Control Center control all start the same root.
public struct AppleDataRootStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gantry/apple-data-root.json")
    }

    /// The shared store at the default location.
    public static let shared = AppleDataRootStore()

    public func load() -> AppleDataRoot {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONDecoder().decode(AppleDataRoot.self, from: data) else {
            return AppleDataRoot()
        }
        return AppleDataRoot(path: root.path)
    }

    public func save(_ root: AppleDataRoot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(AppleDataRoot(path: root.isCustom ? root.path : nil)).write(to: fileURL, options: .atomic)
    }
}
