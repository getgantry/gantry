import Foundation

/// How often a backup runs.
public enum BackupInterval: Sendable, Hashable, Codable {
    case daily
    /// `weekday` uses `Calendar` numbers: 1 is Sunday, 7 is Saturday.
    case weekly(weekday: Int)
}

/// The outcome of the last run of a schedule.
public enum BackupResult: Sendable, Hashable, Codable {
    case succeeded(file: String)
    case failed(message: String)

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A scheduled export of one volume into a folder on this Mac. It holds the
/// settings and the run state. It never holds secrets.
public struct BackupSchedule: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    /// The host name when the schedule was saved, for display.
    public var hostName: String
    public var volume: String
    public var folder: String
    public var interval: BackupInterval
    public var hour: Int
    public var minute: Int
    /// How many archives of this schedule stay in the folder.
    public var keep: Int
    public var createdAt: Date
    public var lastRun: Date?
    public var lastResult: BackupResult?
    /// File names that this schedule wrote. Only these can be deleted.
    public var files: [String]

    public static let keepRange = 1...100

    public init(
        id: UUID = UUID(), hostID: UUID, hostName: String, volume: String, folder: String,
        interval: BackupInterval = .daily, hour: Int = 3, minute: Int = 0, keep: Int = 7,
        createdAt: Date = Date(), lastRun: Date? = nil, lastResult: BackupResult? = nil, files: [String] = []
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.volume = volume
        self.folder = StoragePaths.normalized(folder)
        self.interval = interval
        self.hour = hour
        self.minute = minute
        self.keep = min(max(keep, Self.keepRange.lowerBound), Self.keepRange.upperBound)
        self.createdAt = createdAt
        self.lastRun = lastRun
        self.lastResult = lastResult
        self.files = files
    }
}

/// A failed backup, for a macOS notification.
public struct BackupAlert: Sendable, Hashable {
    public var scheduleID: UUID
    public var hostName: String
    public var volume: String
    public var message: String

    public init(scheduleID: UUID, hostName: String, volume: String, message: String) {
        self.scheduleID = scheduleID
        self.hostName = hostName
        self.volume = volume
        self.message = message
    }

    public var title: String {
        String(localized: "Backup failed", bundle: .module)
    }

    public var body: String {
        String(localized: "The backup of \(volume) on \(hostName) failed: \(message)", bundle: .module)
    }
}

/// Why a backup run could not start or finish.
public enum BackupFailure: LocalizedError, Sendable, Equatable {
    case hostNotFound
    case hostOffline(String)
    case volumeNotFound(String)
    case folderNotFound(String)
    case notAnArchive

    public var errorDescription: String? {
        switch self {
        case .hostNotFound:
            String(localized: "The host is not in Gantry.", bundle: .module)
        case .hostOffline(let name):
            String(localized: "The host \(name) is offline.", bundle: .module)
        case .volumeNotFound(let name):
            String(localized: "The volume \(name) is not on the host.", bundle: .module)
        case .folderNotFound(let path):
            String(localized: "The folder \(path) does not exist.", bundle: .module)
        case .notAnArchive:
            String(localized: "The new file is not a complete tar archive.", bundle: .module)
        }
    }
}
