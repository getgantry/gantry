import Foundation

/// Body of `POST /containers/{id}/update`. A nil field is not sent, so the
/// daemon keeps its value. Docker ignores 0 for `Memory` and `NanoCpus`.
public struct ContainerResourceUpdate: Encodable, Hashable, Sendable {
    public var nanoCPUs: Int64?
    public var memory: Int64?
    public var memoryReservation: Int64?
    /// Memory plus swap, in bytes; -1 removes the swap limit.
    public var memorySwap: Int64?
    public var restartPolicy: ContainerCreateRequest.RestartPolicy?

    enum CodingKeys: String, CodingKey {
        case nanoCPUs = "NanoCpus"
        case memory = "Memory"
        case memoryReservation = "MemoryReservation"
        case memorySwap = "MemorySwap"
        case restartPolicy = "RestartPolicy"
    }

    public init(
        nanoCPUs: Int64? = nil,
        memory: Int64? = nil,
        memoryReservation: Int64? = nil,
        memorySwap: Int64? = nil,
        restartPolicy: ContainerCreateRequest.RestartPolicy? = nil
    ) {
        self.nanoCPUs = nanoCPUs
        self.memory = memory
        self.memoryReservation = memoryReservation
        self.memorySwap = memorySwap
        self.restartPolicy = restartPolicy
    }

    /// Whether the update changes nothing.
    public var isEmpty: Bool {
        nanoCPUs == nil && memory == nil && memoryReservation == nil
            && memorySwap == nil && restartPolicy == nil
    }
}

/// `{ "Warnings": [...] }` of `POST /containers/{id}/update`.
struct ContainerUpdateResponse: Decodable {
    var warnings: [String]?
    enum CodingKeys: String, CodingKey { case warnings = "Warnings" }
}
