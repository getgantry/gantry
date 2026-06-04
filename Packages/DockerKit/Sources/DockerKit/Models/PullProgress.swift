import Foundation

/// One line of the `POST /images/create` JSON-lines progress stream.
///
/// Each line carries a `status` plus an optional layer `id` and byte counts.
/// An `error` line is surfaced by the endpoint as a thrown `DockerError`.
public struct PullProgress: Hashable, Codable, Sendable {
    /// Layer id this line refers to, when the daemon reports per-layer progress.
    public var id: String?
    /// Human-readable status, e.g. "Downloading", "Pull complete".
    public var status: String
    /// Bytes transferred so far for this layer, when known.
    public var current: Int64?
    /// Total bytes for this layer, when known.
    public var total: Int64?
    /// Error text, present only on a failed pull.
    public var error: String?

    public init(
        id: String? = nil,
        status: String = "",
        current: Int64? = nil,
        total: Int64? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.status = status
        self.current = current
        self.total = total
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case progressDetail
        case error
    }

    enum ProgressDetailKeys: String, CodingKey {
        case current
        case total
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)

        if let detail = try? c.nestedContainer(keyedBy: ProgressDetailKeys.self, forKey: .progressDetail) {
            current = try detail.decodeIfPresent(Int64.self, forKey: .current)
            total = try detail.decodeIfPresent(Int64.self, forKey: .total)
        } else {
            current = nil
            total = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(error, forKey: .error)
        if current != nil || total != nil {
            var detail = c.nestedContainer(keyedBy: ProgressDetailKeys.self, forKey: .progressDetail)
            try detail.encodeIfPresent(current, forKey: .current)
            try detail.encodeIfPresent(total, forKey: .total)
        }
    }
}
