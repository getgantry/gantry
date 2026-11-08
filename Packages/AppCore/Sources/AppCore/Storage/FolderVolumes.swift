import Foundation
import Observation

/// A volume that is a folder on a disk. apple/container keeps named volumes
/// only inside its data root, so Gantry records these folders itself and
/// mounts them as bind mounts.
public struct FolderVolume: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var name: String
    public var path: String
    /// The host the volume belongs to.
    public var hostID: UUID
    public var createdAt: Date

    public var id: String { name }

    public init(name: String, path: String, hostID: UUID, createdAt: Date = Date()) {
        self.name = name
        self.path = StoragePaths.normalized(path)
        self.hostID = hostID
        self.createdAt = createdAt
    }

    /// The `-v` value that mounts the folder at `target`.
    public func bindSpec(target: String, readOnly: Bool = false) -> String {
        "\(path):\(target)" + (readOnly ? ":ro" : "")
    }
}

public enum FolderVolumeError: Error, LocalizedError, Sendable, Equatable {
    case invalidName(String)
    case nameTaken(String)
    case notAbsolute(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            String(localized: "“\(name)” is not a valid volume name. Use letters, digits, “_”, “.” and “-”, and start with a letter or a digit.", bundle: .module)
        case .nameTaken(let name):
            String(localized: "A volume with the name “\(name)” already exists.", bundle: .module)
        case .notAbsolute(let path):
            String(localized: "\(path) is not a full path.", bundle: .module)
        }
    }
}

/// Rules for folder volumes.
public enum FolderVolumeRules {
    /// Docker's volume name rule: `[a-zA-Z0-9][a-zA-Z0-9_.-]+`.
    public static func isValidName(_ name: String) -> Bool {
        let first = CharacterSet.alphanumerics
        let rest = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard name.count >= 2, let head = name.unicodeScalars.first, name.unicodeScalars.allSatisfy(rest.contains) else {
            return false
        }
        return first.contains(head) && head.isASCII
    }

    /// The folder for a new volume: `<parent>/<name>`.
    public static func folder(named name: String, in parent: String) -> String {
        StoragePaths.normalized(parent) + "/" + name
    }

    /// The Docker `local` driver options that make a volume a bind of
    /// `path`. Docker supports this natively.
    public static func dockerBindOptions(path: String) -> [String: String] {
        ["type": "none", "o": "bind", "device": StoragePaths.normalized(path)]
    }

    /// The folder of a Docker volume made with ``dockerBindOptions(path:)``.
    public static func dockerBindPath(options: [String: String]?) -> String? {
        guard let options, options["type"] == "none", options["o"]?.split(separator: ",").contains("bind") == true,
              let device = options["device"], device.hasPrefix("/") else { return nil }
        return device
    }
}

/// Stores folder volumes in `~/Library/Application Support/Gantry/folder-volumes.json`.
@MainActor
@Observable
public final class FolderVolumeStore {
    public private(set) var volumes: [FolderVolume] = []
    @ObservationIgnored let fileURL: URL?

    /// The shared store at the default location.
    public static let shared = FolderVolumeStore(fileURL: FolderVolumeStore.defaultFileURL)

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gantry/folder-volumes.json")
    }

    /// `fileURL` nil keeps the store in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            volumes = (try? decoder.decode([FolderVolume].self, from: data)) ?? []
        }
    }

    public func volumes(for hostID: UUID) -> [FolderVolume] {
        volumes.filter { $0.hostID == hostID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Paths by name for one host, for the disk checks.
    public func paths(for hostID: UUID) -> [String: String] {
        Dictionary(volumes(for: hostID).map { ($0.name, $0.path) }, uniquingKeysWith: { a, _ in a })
    }

    public func volume(named name: String, hostID: UUID) -> FolderVolume? {
        volumes.first { $0.hostID == hostID && $0.name == name }
    }

    /// Records a folder volume. `takenNames` are the host's named volumes.
    @discardableResult
    public func add(name: String, path: String, hostID: UUID, takenNames: Set<String> = []) throws -> FolderVolume {
        guard FolderVolumeRules.isValidName(name) else { throw FolderVolumeError.invalidName(name) }
        guard path.hasPrefix("/") else { throw FolderVolumeError.notAbsolute(path) }
        if takenNames.contains(name) || volume(named: name, hostID: hostID) != nil {
            throw FolderVolumeError.nameTaken(name)
        }
        let volume = FolderVolume(name: name, path: path, hostID: hostID)
        volumes.append(volume)
        try save()
        return volume
    }

    /// Forgets a folder volume. The folder and its files stay on the disk.
    public func remove(name: String, hostID: UUID) throws {
        volumes.removeAll { $0.hostID == hostID && $0.name == name }
        try save()
    }

    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(volumes).write(to: fileURL, options: .atomic)
    }
}
