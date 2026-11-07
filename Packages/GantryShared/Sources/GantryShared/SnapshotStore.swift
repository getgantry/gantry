import Foundation

/// Identifiers that the app and the extension must agree on.
public enum SharedIdentifiers {
    /// An App Group for the app and the extension. Not in use: Xcode asks for
    /// a provisioning profile for this entitlement, and release builds are
    /// ad-hoc signed. See `SnapshotStore.standard(includeAppGroup:)`.
    public static let appGroup = "group.com.andrewkomkov.Gantry"
    /// The URL scheme that carries control requests to the app.
    public static let urlScheme = "gantry"

    public static let fleetWidgetKind = "com.andrewkomkov.Gantry.FleetHealth"
    public static let appleServicesControlKind = "com.andrewkomkov.Gantry.AppleServicesControl"
    public static let containerControlKind = "com.andrewkomkov.Gantry.ContainerControl"
}

/// Reads and writes the fleet snapshot in `~/Library/Application Support/
/// Gantry/Widgets`. The sandboxed extension reads that folder through a
/// read-only temporary exception. With several locations, writes go to all
/// and reads take the newest copy.
public struct SnapshotStore: Sendable {
    public static let fileName = "fleet-snapshot.json"
    /// The fallback folder, relative to the user's home folder.
    public static let fallbackRelativePath = "Library/Application Support/Gantry/Widgets"

    public let locations: [URL]

    public init(locations: [URL]) {
        self.locations = locations
    }

    /// The Application Support file, after the App Group file when asked for
    /// (only a build signed with a team and a profile has the App Group).
    public static func standard(includeAppGroup: Bool = false, fileManager: FileManager = .default) -> SnapshotStore {
        var urls: [URL] = []
        if includeAppGroup,
           let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedIdentifiers.appGroup) {
            urls.append(group.appendingPathComponent(fileName))
        }
        let fallback = realHomeDirectory()
            .appendingPathComponent(fallbackRelativePath, isDirectory: true)
            .appendingPathComponent(fileName)
        urls.append(fallback)
        return SnapshotStore(locations: urls)
    }

    /// The user's real home folder. In a sandbox, `NSHomeDirectory()` is the
    /// container, so this reads the password database instead.
    public static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Writes to every location. Returns how many writes worked; throws only
    /// when none did.
    @discardableResult
    public func write(_ snapshot: FleetSnapshot, fileManager: FileManager = .default) throws -> Int {
        let data = try Self.encoder().encode(snapshot)
        var written = 0
        var lastError: Error?
        for url in locations {
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written += 1
            } catch {
                lastError = error
            }
        }
        if written == 0, let lastError { throw lastError }
        return written
    }

    /// The newest snapshot that decodes and has the current version.
    public func read() -> FleetSnapshot? {
        let decoder = Self.decoder()
        let snapshots = locations.compactMap { url -> FleetSnapshot? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(FleetSnapshot.self, from: data),
                  snapshot.version == FleetSnapshot.currentVersion else { return nil }
            return snapshot
        }
        return snapshots.max { $0.generatedAt < $1.generatedAt }
    }
}
