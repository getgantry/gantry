import Foundation

/// Registry digests by canonical reference, with the date of each check.
/// The file holds no credentials, only references, digests and dates.
public struct ImageUpdateCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Nil after a failed check.
        public var digest: String?
        public var checkedAt: Date
    }

    /// A successful result is used for 6 hours.
    public static let successInterval: TimeInterval = 6 * 3600
    /// After a failure (no network, rate limit) the next try is after 1 hour.
    public static let failureInterval: TimeInterval = 3600

    public var entries: [String: Entry] = [:]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The last known remote digest; nil when unknown or the last check failed.
    public func remoteDigest(for key: String) -> String? {
        entries[key]?.digest
    }

    /// Whether `key` needs a request now.
    public func isDue(_ key: String, now: Date) -> Bool {
        guard let entry = entries[key] else { return true }
        let interval = entry.digest == nil ? Self.failureInterval : Self.successInterval
        return now.timeIntervalSince(entry.checkedAt) >= interval
    }

    public mutating func record(_ key: String, digest: String?, at date: Date) {
        entries[key] = Entry(digest: digest, checkedAt: date)
    }

    /// Removes entries that are older than a week.
    public mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.checkedAt) < 7 * 24 * 3600 }
    }

    // MARK: - File

    /// `~/Library/Application Support/Gantry/image-updates.json`, or the path
    /// in `GANTRY_IMAGE_UPDATES_PATH` (test runs of a Debug build).
    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["GANTRY_IMAGE_UPDATES_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gantry/image-updates.json")
    }

    /// Reads the file; an empty cache when it is missing or bad.
    public static func load(from url: URL = defaultURL) -> ImageUpdateCache {
        guard let data = try? Data(contentsOf: url) else { return ImageUpdateCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ImageUpdateCache.self, from: data)) ?? ImageUpdateCache()
    }

    public func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
