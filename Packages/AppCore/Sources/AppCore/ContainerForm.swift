import Foundation
import DockerKit

/// Validation and helpers shared by the Create Container and Quick Run sheets.
/// Kept out of the views so they are unit-tested and never trap on user input.
public enum ContainerForm {
    /// One port row as the sheet holds it.
    public struct PortEntry: Sendable, Equatable {
        public var host: String
        public var container: String
        public var proto: String

        public init(host: String, container: String, proto: String = "tcp") {
            self.host = host
            self.container = container
            self.proto = proto
        }

        var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
        var trimmedContainer: String { container.trimmingCharacters(in: .whitespaces) }

        /// The `80/tcp` key the create request uses.
        public var key: String { "\(trimmedContainer)/\(proto)" }
    }

    /// Why a port row cannot be used.
    public enum PortIssue: Sendable, Equatable {
        case invalidContainerPort
        case invalidHostPort
        case duplicateContainerPort

        public var message: String {
            switch self {
            case .invalidContainerPort:
                String(localized: "The container port must be a number from 1 to 65535.", bundle: .module)
            case .invalidHostPort:
                String(localized: "The host port must be a number from 1 to 65535.", bundle: .module)
            case .duplicateContainerPort:
                String(localized: "This container port is already mapped in another row.", bundle: .module)
            }
        }
    }

    /// The issue for each row index, for rows that would be sent. A row with
    /// an empty container port is skipped by the request, so it has no issue.
    /// `requireHost` mirrors Quick Run, which drops rows without a host port.
    public static func portIssues(_ rows: [PortEntry], requireHost: Bool = false) -> [Int: PortIssue] {
        var issues: [Int: PortIssue] = [:]
        var seen: Set<String> = []
        for (index, row) in rows.enumerated() {
            guard isIncluded(row, requireHost: requireHost) else { continue }
            if !isPort(row.trimmedContainer) {
                issues[index] = .invalidContainerPort
            } else if !row.trimmedHost.isEmpty, !isPort(row.trimmedHost) {
                issues[index] = .invalidHostPort
            } else if !seen.insert(row.key).inserted {
                issues[index] = .duplicateContainerPort
            }
        }
        return issues
    }

    /// The `"80/tcp": "8080"` map for the create request. Never traps: when
    /// two rows share a container port, the first row wins (the sheet blocks
    /// that case anyway through ``portIssues(_:requireHost:)``).
    public static func portMap(_ rows: [PortEntry], requireHost: Bool = false) -> [String: String] {
        var map: [String: String] = [:]
        for row in rows where isIncluded(row, requireHost: requireHost) && map[row.key] == nil {
            map[row.key] = row.trimmedHost
        }
        return map
    }

    private static func isIncluded(_ row: PortEntry, requireHost: Bool) -> Bool {
        !row.trimmedContainer.isEmpty && (!requireHost || !row.trimmedHost.isEmpty)
    }

    private static func isPort(_ text: String) -> Bool {
        guard let value = Int(text) else { return false }
        return (1...65535).contains(value)
    }

    // MARK: - Names

    /// A friendly name from an image reference: `docker.io/library/nginx:alpine`
    /// → `nginx`. Digests and tags are dropped; characters that a container
    /// name cannot hold become `-`. Empty when the image gives nothing usable.
    public static func baseName(forImage image: String) -> String {
        var reference = image.trimmingCharacters(in: .whitespaces)
        if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
        let repo = reference.split(separator: "/").last.map(String.init) ?? reference
        let base = repo.split(separator: ":").first.map(String.init) ?? repo
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let cleaned = String(base.map { allowed.contains($0) ? $0 : "-" })
        // A name must start with a letter or digit.
        return String(cleaned.drop(while: { !$0.isLetter && !$0.isNumber }))
    }

    /// `base` when free, else the first free `base-2`, `base-3`, …
    public static func uniqueName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// True when `name` is a valid container name: `[a-zA-Z0-9][a-zA-Z0-9_.-]*`,
    /// the rule Docker applies.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        return name.allSatisfy { allowed.contains($0) }
    }

    /// Whether a rename to `text` may go ahead: a valid name that differs
    /// from the current one (surrounding spaces are ignored).
    public static func isValidRename(_ text: String, current: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespaces)
        return isValidName(name) && name != current
    }

    /// The inline problem with a typed container name, or nil when it can be
    /// used. An empty name is fine: the runtime then picks one.
    public static func nameIssue(_ text: String, taken: Set<String>) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if !isValidName(name) {
            return String(localized: "Use letters, digits, “_”, “.” and “-”, starting with a letter or digit.", bundle: .module)
        }
        return taken.contains(name) ? nameInUseMessage(name) : nil
    }

    /// The names in use on a host, without Docker's leading `/`.
    public static func takenNames(_ containers: [ContainerSummary]) -> Set<String> {
        var result: Set<String> = []
        for container in containers {
            result.insert(container.displayName)
            for name in container.names {
                result.insert(name.hasPrefix("/") ? String(name.dropFirst()) : name)
            }
        }
        return result
    }

    /// True when a create failed because the name is in use. Docker answers
    /// 409 "Conflict. The container name ... is already in use"; the apple CLI
    /// says "already exists".
    public static func isNameConflict(_ error: Error) -> Bool {
        if case let DockerError.apiError(status, message) = error {
            if status == 409 { return true }
            return mentionsNameConflict(message)
        }
        return mentionsNameConflict(error.localizedDescription)
    }

    static func mentionsNameConflict(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("already in use") || text.contains("already exists")
    }

    /// The inline message for a name conflict.
    public static func nameInUseMessage(_ name: String) -> String {
        String(localized: "A container named “\(name)” already exists. Choose another name.", bundle: .module)
    }
}
