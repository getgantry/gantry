import Foundation
import DockerKit

/// Memory sizes as `docker run -m` takes them: binary units, a number with no
/// unit is MiB. `format` gives back a text that `parse` reads to the same bytes.
public enum MemorySize {
    private static let units: [(suffix: String, bytes: Int64)] = [
        ("t", 1 << 40), ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10)
    ]

    /// Bytes of `text`, or nil when it is not a positive size.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        guard let multiplier = multiplier(String(trimmed.dropFirst(number.count))) else { return nil }
        let bytes = (value * Double(multiplier)).rounded()
        guard bytes >= 1, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    /// The bytes of one unit text: "", "m", "mb", "mi", "mib", "b" and so on.
    private static func multiplier(_ unit: String) -> Int64? {
        var unit = unit.trimmingCharacters(in: .whitespaces)
        if unit.isEmpty { return 1 << 20 }
        if unit == "b" { return 1 }
        if unit.hasSuffix("b") { unit.removeLast() }
        if unit.hasSuffix("i") { unit.removeLast() }
        return units.first { $0.suffix == unit }?.bytes
    }

    /// The shortest exact text: 536870912 → "512m", 1610612736 → "1536m".
    public static func format(_ bytes: Int64) -> String {
        for unit in units where bytes >= unit.bytes && bytes % unit.bytes == 0 {
            return "\(bytes / unit.bytes)\(unit.suffix)"
        }
        return "\(bytes)b"
    }
}

/// The limits and the restart policy of a container, from inspect.
/// A limit of 0 means none; a `memorySwap` of -1 means no swap limit.
public struct ContainerResources: Equatable, Sendable {
    public var nanoCPUs: Int64
    public var memory: Int64
    public var memoryReservation: Int64
    public var memorySwap: Int64
    public var restartPolicy: String
    public var maxRetries: Int

    public init(
        nanoCPUs: Int64 = 0, memory: Int64 = 0, memoryReservation: Int64 = 0,
        memorySwap: Int64 = 0, restartPolicy: String = "no", maxRetries: Int = 0
    ) {
        self.nanoCPUs = nanoCPUs
        self.memory = memory
        self.memoryReservation = memoryReservation
        self.memorySwap = memorySwap
        self.restartPolicy = restartPolicy
        self.maxRetries = maxRetries
    }

    public init(details: ContainerDetails) {
        let host = details.hostConfig
        let policy = host.restartPolicy?.name ?? ""
        self.init(
            nanoCPUs: max(host.nanoCpus ?? 0, 0),
            memory: max(host.memory ?? 0, 0),
            memoryReservation: max(host.memoryReservation ?? 0, 0),
            memorySwap: host.memorySwap ?? 0,
            restartPolicy: policy.isEmpty ? "no" : policy,
            maxRetries: host.restartPolicy?.maximumRetryCount ?? 0
        )
    }

    /// Cores as text: 500000000 → "0.5", 2000000000 → "2".
    public static func coresText(_ nanoCPUs: Int64) -> String {
        let cores = Double(nanoCPUs) / 1_000_000_000
        return cores.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
