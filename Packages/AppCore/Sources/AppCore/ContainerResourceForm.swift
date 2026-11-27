import Foundation
import DockerKit

/// The fields of the Edit Resources sheet, their checks and the change they
/// make. Docker updates a running container; apple/container 1.7.1 has no
/// update command, so an Apple host recreates the container with CPUs and memory.
public struct ContainerResourceForm: Equatable, Sendable {
    public enum Engine: Equatable, Sendable { case docker, apple }

    public enum Field: String, CaseIterable, Sendable {
        case cpus, memory, memoryReservation, memorySwap, restartPolicy
    }

    /// The restart policies of Docker, in menu order.
    public static let restartPolicies = ["no", "on-failure", "always", "unless-stopped"]
    /// The smallest memory apple/container accepts (`minimumMemoryInBytes`).
    public static let appleMinimumMemory: Int64 = 200 << 20

    public let engine: Engine
    public let original: ContainerResources
    /// The CPU count of the host; 0 when it is not known.
    public let hostCPUs: Int

    public var cpus: String
    public var memory: String
    public var memoryReservation: String
    public var memorySwap: String
    public var restartPolicy: String
    public var maxRetries: String

    public init(original: ContainerResources, engine: Engine, hostCPUs: Int) {
        self.engine = engine
        self.original = original
        self.hostCPUs = hostCPUs
        cpus = original.nanoCPUs > 0 ? ContainerResources.coresText(original.nanoCPUs) : ""
        memory = original.memory > 0 ? MemorySize.format(original.memory) : ""
        memoryReservation = original.memoryReservation > 0 ? MemorySize.format(original.memoryReservation) : ""
        memorySwap = original.memorySwap == -1 ? "-1"
            : original.memorySwap > 0 ? MemorySize.format(original.memorySwap) : ""
        restartPolicy = original.restartPolicy
        maxRetries = String(original.maxRetries)
    }

    /// The fields that the engine can change.
    public var fields: [Field] {
        engine == .apple ? [.cpus, .memory] : Field.allCases
    }

    // MARK: - Parsed values

    /// A parsed field: an empty field, a value, or a bad text.
    enum Parsed: Equatable { case empty, value(Int64), invalid }

    func parsedCPUs() -> Parsed {
        let text = cpus.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if text.isEmpty { return .empty }
        guard let cores = Double(text), cores > 0, cores.isFinite else { return .invalid }
        return .value(Int64((cores * 1_000_000_000).rounded()))
    }

    func parsedSize(_ text: String, allowUnlimited: Bool = false) -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return .empty }
        if allowUnlimited, trimmed == "-1" || trimmed == "unlimited" { return .value(-1) }
        return MemorySize.parse(trimmed).map(Parsed.value) ?? .invalid
    }

    // MARK: - Checks

    /// The problem of one field, or nil when the field is good.
    public func error(for field: Field) -> String? {
        switch field {
        case .cpus: cpusError()
        case .memory: sizeError(parsedSize(memory), original: original.memory, minimum: engine == .apple ? Self.appleMinimumMemory : nil)
        case .memoryReservation: sizeError(parsedSize(memoryReservation), original: original.memoryReservation, minimum: nil)
        case .memorySwap: swapError()
        case .restartPolicy: retriesError()
        }
    }

    private func cpusError() -> String? {
        let parsed = parsedCPUs()
        switch parsed {
        case .invalid:
            return String(localized: "Enter a positive number of cores, for example 0.5 or 2.", bundle: .module)
        case .empty:
            return emptyError(original: original.nanoCPUs)
        case .value(let nano):
            if engine == .apple, nano % 1_000_000_000 != 0 {
                return String(localized: "apple/container takes a whole number of CPUs.", bundle: .module)
            }
            if hostCPUs > 0, nano > Int64(hostCPUs) * 1_000_000_000 {
                return String(localized: "Enter at most \(hostCPUs), the CPU count of the host.", bundle: .module)
            }
            return nil
        }
    }

    private func sizeError(_ parsed: Parsed, original: Int64, minimum: Int64?) -> String? {
        switch parsed {
        case .invalid:
            return String(localized: "Enter a size, for example 512m or 2g.", bundle: .module)
        case .empty:
            return emptyError(original: original)
        case .value(let bytes):
            if let minimum, bytes < minimum {
                return String(localized: "apple/container needs at least 200 MiB.", bundle: .module)
            }
            return nil
        }
    }

    private func swapError() -> String? {
        switch parsedSize(memorySwap, allowUnlimited: true) {
        case .invalid:
            return String(localized: "Enter a size, or -1 for no swap limit.", bundle: .module)
        case .empty where original.memorySwap != 0:
            return String(localized: "Enter -1 to remove the swap limit.", bundle: .module)
        default:
            return nil
        }
    }

    private func retriesError() -> String? {
        guard restartPolicy == "on-failure" else { return nil }
        if let count = Int(maxRetries.trimmingCharacters(in: .whitespaces)), count >= 0 { return nil }
        return String(localized: "Enter 0 or a positive whole number.", bundle: .module)
    }

    /// An empty field: fine when there was no limit. Docker ignores 0 in an
    /// update and apple/container always has a value, so a limit stays.
    private func emptyError(original: Int64) -> String? {
        if engine == .apple { return String(localized: "Enter a value.", bundle: .module) }
        guard original > 0 else { return nil }
        return String(localized: "Docker cannot remove this limit from a container. Enter a value.", bundle: .module)
    }

    /// Whether every shown field is good.
    public var isValid: Bool { fields.allSatisfy { error(for: $0) == nil } }

    /// Whether a field differs from the container.
    public var hasChanges: Bool {
        switch engine {
        case .docker: !(dockerUpdate()?.isEmpty ?? true)
        case .apple: appleLimits().map { $0.nanoCPUs != original.nanoCPUs || $0.memory != original.memory } ?? false
        }
    }

    // MARK: - Changes

    /// The update body with only the changed fields; nil when a field is bad.
    public func dockerUpdate() -> ContainerResourceUpdate? {
        guard engine == .docker, isValid else { return nil }
        var update = ContainerResourceUpdate()
        update.nanoCPUs = changed(parsedCPUs(), original.nanoCPUs)
        update.memory = changed(parsedSize(memory), original.memory)
        update.memoryReservation = changed(parsedSize(memoryReservation), original.memoryReservation)
        update.memorySwap = changed(parsedSize(memorySwap, allowUnlimited: true), original.memorySwap)
        let retries = restartPolicy == "on-failure" ? Int(maxRetries.trimmingCharacters(in: .whitespaces)) ?? 0 : 0
        let originalRetries = original.restartPolicy == "on-failure" ? original.maxRetries : 0
        if restartPolicy != original.restartPolicy || retries != originalRetries {
            update.restartPolicy = .init(name: restartPolicy, maximumRetryCount: retries)
        }
        return update
    }

    private func changed(_ parsed: Parsed, _ original: Int64) -> Int64? {
        guard case .value(let value) = parsed, value != original else { return nil }
        return value
    }

    /// The CPUs and memory of the recreated Apple container; nil when bad.
    public func appleLimits() -> (nanoCPUs: Int64, memory: Int64)? {
        guard engine == .apple, isValid,
              case .value(let nano) = parsedCPUs(),
              case .value(let bytes) = parsedSize(memory) else { return nil }
        return (nano, bytes)
    }

    /// Puts the new Apple limits into the create request of a recreate.
    public func applyAppleLimits(to request: inout ContainerCreateRequest) {
        guard let limits = appleLimits() else { return }
        var host = request.hostConfig ?? ContainerCreateRequest.HostConfig()
        host.nanoCPUs = limits.nanoCPUs
        host.memory = limits.memory
        request.hostConfig = host
    }
}
