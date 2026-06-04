import Foundation

/// Summary of `GET /system/df`.
///
/// The raw response carries full object arrays per category; we model only the
/// totals: the shared layer size plus per-category counts and aggregate sizes.
/// Decoding is tolerant — any missing category collapses to zero.
public struct SystemDiskUsage: Hashable, Decodable, Sendable {
    public var layersSize: Int64
    public var imagesCount: Int
    public var imagesSize: Int64
    public var containersCount: Int
    public var containersSize: Int64
    public var volumesCount: Int
    public var volumesSize: Int64

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize"
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
    }

    private struct ImageRow: Decodable {
        var size: Int64
        enum CodingKeys: String, CodingKey { case size = "Size" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        }
    }

    private struct ContainerRow: Decodable {
        var sizeRw: Int64
        enum CodingKeys: String, CodingKey { case sizeRw = "SizeRw" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sizeRw = try c.decodeIfPresent(Int64.self, forKey: .sizeRw) ?? 0
        }
    }

    private struct VolumeRow: Decodable {
        var size: Int64
        enum UsageKeys: String, CodingKey { case size = "Size" }
        enum CodingKeys: String, CodingKey { case usageData = "UsageData" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let usage = try? c.nestedContainer(keyedBy: UsageKeys.self, forKey: .usageData) {
                size = try usage.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            } else {
                size = 0
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layersSize = try c.decodeIfPresent(Int64.self, forKey: .layersSize) ?? 0

        let images = try c.decodeIfPresent([ImageRow].self, forKey: .images) ?? []
        imagesCount = images.count
        imagesSize = images.reduce(0) { $0 + max($1.size, 0) }

        let containers = try c.decodeIfPresent([ContainerRow].self, forKey: .containers) ?? []
        containersCount = containers.count
        containersSize = containers.reduce(0) { $0 + max($1.sizeRw, 0) }

        let volumes = try c.decodeIfPresent([VolumeRow].self, forKey: .volumes) ?? []
        volumesCount = volumes.count
        volumesSize = volumes.reduce(0) { $0 + max($1.size, 0) }
    }

    public init(
        layersSize: Int64,
        imagesCount: Int, imagesSize: Int64,
        containersCount: Int, containersSize: Int64,
        volumesCount: Int, volumesSize: Int64
    ) {
        self.layersSize = layersSize
        self.imagesCount = imagesCount
        self.imagesSize = imagesSize
        self.containersCount = containersCount
        self.containersSize = containersSize
        self.volumesCount = volumesCount
        self.volumesSize = volumesSize
    }
}
