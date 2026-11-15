import Foundation
import DockerKit

/// Folds the lines of an image pull into per-layer state, layers done and
/// bytes. Docker sends one line per layer event with byte counts;
/// apple/container sends lines without a layer id that carry a percent
/// (`current` of 100).
public struct PullProgressTracker: Sendable {
    /// Layer ids in the order they first showed.
    public private(set) var layerOrder: [String] = []
    /// The newest line for each layer.
    public private(set) var layers: [String: PullProgress] = [:]
    /// The last line without a layer id ("Digest: …", apple/container progress).
    public private(set) var statusLine = ""
    /// The last overall percent from a line without a layer id, 0...1.
    public private(set) var overallPercent: Double?
    /// Byte totals that layers reported; they stay after the layer is done,
    /// when Docker stops sending counts.
    private var layerTotals: [String: Int64] = [:]
    private var completed: Set<String> = []

    public init() {}

    /// Docker statuses after which a layer needs no more work.
    static let doneStatuses = ["pull complete", "already exists"]
    /// Docker statuses after the download of a layer ends.
    static let downloadedStatuses = ["verifying", "download complete", "extracting"]

    public mutating func apply(_ line: PullProgress) {
        if let id = line.id, !id.isEmpty, Self.isLayerID(id) {
            if layers[id] == nil { layerOrder.append(id) }
            layers[id] = line
            if let total = line.total, total > 0 { layerTotals[id] = total }
            let status = line.status.lowercased()
            if Self.doneStatuses.contains(where: { status.hasPrefix($0) }) { completed.insert(id) }
        } else if !line.status.isEmpty {
            statusLine = line.status
            if line.id == nil, line.total == 100, let current = line.current {
                overallPercent = min(max(Double(current) / 100, 0), 1)
            }
        }
    }

    /// Docker also sends lines with the tag as id ("17: Pulling from …");
    /// layer ids are short hex digests.
    static func isLayerID(_ id: String) -> Bool {
        id.count >= 8 && id.allSatisfy(\.isHexDigit)
    }

    public var layersDone: Int { completed.count }
    public var layersTotal: Int { layerOrder.count }

    /// Bytes downloaded over the bytes of the layers that report sizes. A
    /// done layer counts as all of its bytes.
    public var bytes: OperationProgress.Bytes? {
        guard !layerTotals.isEmpty else { return nil }
        var done: Int64 = 0
        var total: Int64 = 0
        for (id, size) in layerTotals {
            total += size
            let status = layers[id]?.status.lowercased() ?? ""
            if completed.contains(id) || Self.downloadedStatuses.contains(where: { status.hasPrefix($0) }) {
                done += size
            } else if status.hasPrefix("downloading") {
                done += min(layers[id]?.current ?? 0, size)
            }
        }
        return OperationProgress.Bytes(done: done, total: total)
    }

    public var progress: OperationProgress {
        let items = layersTotal > 0
            ? OperationProgress.Items(done: layersDone, total: layersTotal, unit: .layers)
            : nil
        return OperationProgress(items: items, bytes: bytes)
    }

    /// Bytes first, then the apple/container percent, then layers.
    public var fraction: Double? {
        progress.bytes?.fraction ?? overallPercent ?? progress.items?.fraction
    }
}
