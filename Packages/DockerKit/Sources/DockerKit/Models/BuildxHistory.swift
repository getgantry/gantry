import Foundation

/// One record of `docker buildx history ls --format json`.
public struct BuildxRecord: Sendable, Equatable {
    /// The full reference, e.g. `default/default/o4kn3a8tluispaxrrvdsh5ypt`.
    public var ref: String
    public var name: String
    /// The text that buildx gives: `Running`, `Completed`, `Canceled`, `Error`.
    public var status: String
    public var createdAt: Date?
    public var completedAt: Date?
    public var totalSteps: Int?
    public var completedSteps: Int?
    public var cachedSteps: Int?

    /// The last part of `ref`: the ID that `inspect` and `logs` take.
    public var id: String { ref.split(separator: "/").last.map(String.init) ?? ref }

    public init(
        ref: String, name: String, status: String, createdAt: Date? = nil, completedAt: Date? = nil,
        totalSteps: Int? = nil, completedSteps: Int? = nil, cachedSteps: Int? = nil
    ) {
        self.ref = ref
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.totalSteps = totalSteps
        self.completedSteps = completedSteps
        self.cachedSteps = cachedSteps
    }
}

/// The fields of `docker buildx history inspect --format json` that Gantry shows.
public struct BuildxInspect: Sendable, Equatable {
    public var name: String?
    public var context: String?
    public var dockerfile: String?
    public var status: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?
    /// The step that failed, e.g. `[3/3] RUN exit 3`.
    public var errorStep: String?

    public init(
        name: String? = nil, context: String? = nil, dockerfile: String? = nil, status: String? = nil,
        startedAt: Date? = nil, completedAt: Date? = nil, errorMessage: String? = nil, errorStep: String? = nil
    ) {
        self.name = name
        self.context = context
        self.dockerfile = dockerfile
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.errorStep = errorStep
    }
}

/// Parses the output of `docker buildx history` and `docker buildx version`.
///
/// buildx 0.29.1 prints one object per line with snake_case keys; the docs
/// show an array with CamelCase keys. Both are accepted.
public enum BuildxHistoryParser {
    /// The oldest buildx with the `history` commands and JSON output that Gantry uses.
    public static let minimumVersion = "0.23.0"

    public static func records(from text: String) throws -> [BuildxRecord] {
        try objects(from: text).compactMap(record)
    }

    public static func inspect(from text: String) throws -> BuildxInspect {
        guard let object = try objects(from: text).first else { throw DockerError.decodingFailed("empty buildx inspect output") }
        let error = object["Error"] as? [String: Any]
        return BuildxInspect(
            name: string(object, "Name", "name"),
            context: string(object, "Context", "context"),
            dockerfile: string(object, "Dockerfile", "dockerfile"),
            status: string(object, "Status", "status"),
            startedAt: date(string(object, "StartedAt", "started_at")),
            completedAt: date(string(object, "CompletedAt", "completed_at")),
            errorMessage: error.flatMap { string($0, "Message", "message") },
            errorStep: error.flatMap { string($0, "Name", "name") }
        )
    }

    /// `github.com/docker/buildx v0.29.1 a32761a…` → `0.29.1`.
    public static func version(from text: String) -> String? {
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = word.hasPrefix("v") ? word.dropFirst() : word[...]
            let core = candidate.prefix { $0.isNumber || $0 == "." }
            let parts = core.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) { return String(core) }
        }
        return nil
    }

    /// True when `version` is `minimumVersion` or later.
    public static func isSupported(_ version: String) -> Bool {
        let have = version.split(separator: ".").map { Int($0) ?? 0 }
        let need = minimumVersion.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(have.count, need.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < need.count ? need[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    // MARK: - Helpers

    static func objects(from text: String) throws -> [[String: Any]] {
        do {
            return try decodeObjects(text)
        } catch let error as DockerError {
            throw error
        } catch {
            throw DockerError.decodingFailed("buildx output is not JSON: \(text.prefix(200))")
        }
    }

    private static func decodeObjects(_ text: String) throws -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") {
            guard let array = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] else {
                throw DockerError.decodingFailed("buildx output is not a list of objects")
            }
            return array
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            return [object]
        }
        return try trimmed.split(separator: "\n").compactMap { line -> [String: Any]? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw DockerError.decodingFailed("buildx output line is not an object")
            }
            return object
        }
    }

    static func record(_ object: [String: Any]) -> BuildxRecord? {
        guard let ref = string(object, "ref", "Ref", "ID", "id") else { return nil }
        return BuildxRecord(
            ref: ref,
            name: string(object, "name", "Name") ?? "",
            status: string(object, "status", "Status") ?? "",
            createdAt: date(string(object, "created_at", "CreatedAt", "createdAt")),
            completedAt: date(string(object, "completed_at", "CompletedAt", "completedAt")),
            totalSteps: int(object, "total_steps", "TotalSteps", "NumTotalSteps"),
            completedSteps: int(object, "completed_steps", "CompletedSteps", "NumCompletedSteps"),
            cachedSteps: int(object, "cached_steps", "CachedSteps", "NumCachedSteps")
        )
    }

    static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func int(_ object: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
        }
        return nil
    }

    /// RFC 3339 with up to nanoseconds (`2026-11-14T15:43:05.578935175Z`).
    public static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        // ISO8601DateFormatter reads at most milliseconds: cut the fraction to 3 digits.
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            text = String(text[..<dot]) + "." + String(digits.prefix(3)) + String(text[end...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
