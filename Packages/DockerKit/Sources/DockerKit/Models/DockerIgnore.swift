import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A parsed `.dockerignore`, used to exclude paths from a build context tar.
///
/// Implements the practical subset of Docker's ignore rules: comments (`#`),
/// blank lines, leading `!` exclusions (re-includes), and `fnmatch`-style
/// wildcards (`*`, `?`, `[…]`) matched per relative path. The full engine also
/// honours `**`; this matcher treats a trailing `dir` as matching everything
/// beneath it, which covers the common cases (`node_modules`, `.git`, `*.log`).
public struct DockerIgnore: Sendable {
    /// One rule: a normalized pattern and whether it re-includes (`!`).
    private struct Rule: Sendable {
        var pattern: String
        var isNegated: Bool
    }

    private let rules: [Rule]

    /// Patterns Docker always ignores regardless of the file's contents.
    private static let alwaysIgnored: Set<String> = [".dockerignore"]

    public init(patterns: [String]) {
        self.rules = patterns.compactMap(Self.parseLine)
    }

    /// Loads `.dockerignore` from a build context directory. Returns an empty
    /// (match-nothing) instance when the file is absent or unreadable.
    public static func load(contextDirectory: URL) -> DockerIgnore {
        let url = contextDirectory.appendingPathComponent(".dockerignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return DockerIgnore(patterns: [])
        }
        return DockerIgnore(patterns: text.components(separatedBy: .newlines))
    }

    private static func parseLine(_ raw: String) -> Rule? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let isNegated = line.hasPrefix("!")
        if isNegated { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        // Normalize: drop a leading "./" and any leading/trailing slashes so the
        // pattern compares against context-relative paths.
        while line.hasPrefix("./") { line.removeFirst(2) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !line.isEmpty else { return nil }
        return Rule(pattern: line, isNegated: isNegated)
    }

    /// Whether `relativePath` (a context-relative path with `/` separators,
    /// no leading slash) should be excluded from the build context.
    public func excludes(_ relativePath: String) -> Bool {
        let path = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if Self.alwaysIgnored.contains(path) { return true }

        // Last matching rule wins, so a later `!pattern` can re-include a path an
        // earlier rule excluded — matching Docker's precedence.
        var excluded = false
        for rule in rules where Self.matches(pattern: rule.pattern, path: path) {
            excluded = !rule.isNegated
        }
        return excluded
    }

    /// Matches a single pattern against a path. A pattern matches the path when
    /// the whole path matches, or when it matches any leading directory of the
    /// path (so `node_modules` excludes `node_modules/foo/bar`).
    private static func matches(pattern: String, path: String) -> Bool {
        if fnmatchPath(pattern, path) { return true }
        // Treat the pattern as a directory prefix: does it match an ancestor?
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if prefix == path { break }
            if fnmatchPath(pattern, prefix) { return true }
        }
        return false
    }

    /// `fnmatch` with `FNM_PATHNAME` so `*` does not cross `/` boundaries.
    private static func fnmatchPath(_ pattern: String, _ string: String) -> Bool {
        pattern.withCString { patternC in
            string.withCString { stringC in
                fnmatch(patternC, stringC, FNM_PATHNAME) == 0
            }
        }
    }
}
