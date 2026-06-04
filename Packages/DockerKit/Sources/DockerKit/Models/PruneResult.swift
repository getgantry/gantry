import Foundation

/// Normalized result of a `*/prune` call.
///
/// Docker returns category-specific shapes (`ImagesDeleted`, `ContainersDeleted`,
/// `VolumesDeleted`, `NetworksDeleted`, `CachesDeleted`) plus an optional
/// `SpaceReclaimed`. This model collapses them into a deleted count and the
/// reclaimed byte count, decoding whichever fields are present.
public struct PruneResult: Hashable, Decodable, Sendable {
    public var deletedCount: Int
    public var spaceReclaimed: Int64

    public init(deletedCount: Int, spaceReclaimed: Int64) {
        self.deletedCount = deletedCount
        self.spaceReclaimed = spaceReclaimed
    }

    enum CodingKeys: String, CodingKey {
        case imagesDeleted = "ImagesDeleted"
        case containersDeleted = "ContainersDeleted"
        case volumesDeleted = "VolumesDeleted"
        case networksDeleted = "NetworksDeleted"
        case cachesDeleted = "CachesDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }

    /// One element of an `ImagesDeleted` array; only its presence matters here.
    private struct DeletedImage: Decodable {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Image prune: array of delete report entries.
        let images = try c.decodeIfPresent([DeletedImage].self, forKey: .imagesDeleted)?.count
        // Container/volume/build prune: arrays of identifiers.
        let containers = try c.decodeIfPresent([String].self, forKey: .containersDeleted)?.count
        let volumes = try c.decodeIfPresent([String].self, forKey: .volumesDeleted)?.count
        let caches = try c.decodeIfPresent([DeletedImage].self, forKey: .cachesDeleted)?.count
        // Network prune: array of network names.
        let networks = try c.decodeIfPresent([String].self, forKey: .networksDeleted)?.count

        deletedCount = (images ?? 0) + (containers ?? 0) + (volumes ?? 0)
            + (caches ?? 0) + (networks ?? 0)
        spaceReclaimed = try c.decodeIfPresent(Int64.self, forKey: .spaceReclaimed) ?? 0
    }
}
