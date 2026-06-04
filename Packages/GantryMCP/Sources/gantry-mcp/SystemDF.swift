import Foundation
import DockerKit

/// Minimal decode of `GET /system/df` (disk usage). DockerKit does not expose a
/// typed endpoint for this, so the MCP server reads the raw JSON via the public
/// `rawJSON` API and summarizes the parts the agent cares about.
struct SystemDiskUsage: Sendable {
    struct Category: Sendable {
        var count: Int
        var totalSizeBytes: Int64
        var reclaimableBytes: Int64
    }

    var images: Category
    var containers: Category
    var volumes: Category
    var buildCacheBytes: Int64
}

extension DockerClient {
    /// `GET /system/df` summarized into per-category counts and sizes.
    func systemDiskUsage() async throws -> SystemDiskUsage {
        let data = try await rawJSON(path: "/system/df")
        let raw = try JSONDecoder().decode(RawSystemDF.self, from: data)

        let images = raw.images ?? []
        let imageTotal = images.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let imageShared = images.reduce(Int64(0)) { $0 + max($1.sharedSize ?? 0, 0) }
        // Reclaimable images: those not referenced by any container.
        let imageReclaimable = images.reduce(Int64(0)) { acc, img in
            (img.containers ?? 0) <= 0 ? acc + ((img.size ?? 0) - max(img.sharedSize ?? 0, 0)) : acc
        }
        _ = imageShared

        let containers = raw.containers ?? []
        let containerTotal = containers.reduce(Int64(0)) { $0 + ($1.sizeRw ?? 0) }
        let containerReclaimable = containers.reduce(Int64(0)) { acc, c in
            (c.state ?? "").lowercased() == "running" ? acc : acc + (c.sizeRw ?? 0)
        }

        let volumes = raw.volumes ?? []
        let volumeTotal = volumes.reduce(Int64(0)) { $0 + ($1.usageData?.size ?? 0) }
        let volumeReclaimable = volumes.reduce(Int64(0)) { acc, v in
            (v.usageData?.refCount ?? 0) <= 0 ? acc + max(v.usageData?.size ?? 0, 0) : acc
        }

        let buildCache = (raw.buildCache ?? []).reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return SystemDiskUsage(
            images: .init(count: images.count, totalSizeBytes: imageTotal, reclaimableBytes: max(imageReclaimable, 0)),
            containers: .init(count: containers.count, totalSizeBytes: containerTotal, reclaimableBytes: containerReclaimable),
            volumes: .init(count: volumes.count, totalSizeBytes: volumeTotal, reclaimableBytes: volumeReclaimable),
            buildCacheBytes: buildCache
        )
    }
}

// MARK: - Raw decode

private struct RawSystemDF: Decodable {
    var images: [RawImage]?
    var containers: [RawContainer]?
    var volumes: [RawVolume]?
    var buildCache: [RawBuildCache]?

    enum CodingKeys: String, CodingKey {
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
        case buildCache = "BuildCache"
    }
}

private struct RawImage: Decodable {
    var size: Int64?
    var sharedSize: Int64?
    var containers: Int?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
        case sharedSize = "SharedSize"
        case containers = "Containers"
    }
}

private struct RawContainer: Decodable {
    var sizeRw: Int64?
    var state: String?

    enum CodingKeys: String, CodingKey {
        case sizeRw = "SizeRw"
        case state = "State"
    }
}

private struct RawVolume: Decodable {
    var usageData: RawUsage?

    enum CodingKeys: String, CodingKey {
        case usageData = "UsageData"
    }

    struct RawUsage: Decodable {
        var size: Int64?
        var refCount: Int?

        enum CodingKeys: String, CodingKey {
            case size = "Size"
            case refCount = "RefCount"
        }
    }
}

private struct RawBuildCache: Decodable {
    var size: Int64?

    enum CodingKeys: String, CodingKey {
        case size = "Size"
    }
}
