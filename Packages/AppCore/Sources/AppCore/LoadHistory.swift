import Foundation
import DockerKit

/// Cumulative counters of one container at one instant, as one-shot stats
/// report them. Rates come from the difference of two of these.
public struct ContainerCounters: Sendable, Hashable {
    public var date: Date
    public var cpuTotal: Int64
    public var systemCPU: Int64
    public var onlineCPUs: Int
    public var memoryBytes: Int64
    public var networkRx: Int64
    public var networkTx: Int64
    public var blockRead: Int64
    public var blockWrite: Int64

    public init(
        date: Date, cpuTotal: Int64, systemCPU: Int64, onlineCPUs: Int, memoryBytes: Int64,
        networkRx: Int64 = 0, networkTx: Int64 = 0, blockRead: Int64 = 0, blockWrite: Int64 = 0
    ) {
        self.date = date
        self.cpuTotal = cpuTotal
        self.systemCPU = systemCPU
        self.onlineCPUs = onlineCPUs
        self.memoryBytes = memoryBytes
        self.networkRx = networkRx
        self.networkTx = networkTx
        self.blockRead = blockRead
        self.blockWrite = blockWrite
    }

    public init(_ sample: ContainerStatsSample, date: Date = .now) {
        self.init(
            date: date,
            cpuTotal: sample.cpuTotalUsage,
            systemCPU: sample.systemCPUUsage,
            onlineCPUs: sample.onlineCPUs,
            memoryBytes: sample.memoryUsageBytes,
            networkRx: sample.networkRxBytes,
            networkTx: sample.networkTxBytes,
            blockRead: sample.blockReadBytes,
            blockWrite: sample.blockWriteBytes
        )
    }
}

/// One point of a container's load: CPU (100 = one core), memory and
/// network / disk rates in bytes per second.
public struct ContainerLoadPoint: Sendable, Hashable {
    public var date: Date
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var networkInRate: Double
    public var networkOutRate: Double
    public var diskReadRate: Double
    public var diskWriteRate: Double

    public init(
        date: Date, cpuPercent: Double, memoryBytes: Int64,
        networkInRate: Double = 0, networkOutRate: Double = 0,
        diskReadRate: Double = 0, diskWriteRate: Double = 0
    ) {
        self.date = date
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.networkInRate = networkInRate
        self.networkOutRate = networkOutRate
        self.diskReadRate = diskReadRate
        self.diskWriteRate = diskWriteRate
    }

    public var networkRate: Double { networkInRate + networkOutRate }
    public var diskRate: Double { diskReadRate + diskWriteRate }
}

public enum LoadMath {
    /// The load between two counter readings. Without a previous reading, or
    /// when a counter went down (restart), the rates are 0.
    public static func point(previous: ContainerCounters?, current: ContainerCounters) -> ContainerLoadPoint {
        var point = ContainerLoadPoint(date: current.date, cpuPercent: 0, memoryBytes: current.memoryBytes)
        guard let previous else { return point }
        let cpuDelta = current.cpuTotal - previous.cpuTotal
        let systemDelta = current.systemCPU - previous.systemCPU
        if cpuDelta > 0, systemDelta > 0 {
            point.cpuPercent = Double(cpuDelta) / Double(systemDelta) * Double(max(current.onlineCPUs, 1)) * 100
        }
        let seconds = current.date.timeIntervalSince(previous.date)
        guard seconds > 0 else { return point }
        point.networkInRate = rate(previous.networkRx, current.networkRx, seconds)
        point.networkOutRate = rate(previous.networkTx, current.networkTx, seconds)
        point.diskReadRate = rate(previous.blockRead, current.blockRead, seconds)
        point.diskWriteRate = rate(previous.blockWrite, current.blockWrite, seconds)
        return point
    }

    static func rate(_ old: Int64, _ new: Int64, _ seconds: TimeInterval) -> Double {
        new > old ? Double(new - old) / seconds : 0
    }

    /// The sum of several container points, dated `date`.
    public static func total(_ points: [ContainerLoadPoint], date: Date) -> ContainerLoadPoint {
        points.reduce(into: ContainerLoadPoint(date: date, cpuPercent: 0, memoryBytes: 0)) { sum, p in
            sum.cpuPercent += p.cpuPercent
            sum.memoryBytes += p.memoryBytes
            sum.networkInRate += p.networkInRate
            sum.networkOutRate += p.networkOutRate
            sum.diskReadRate += p.diskReadRate
            sum.diskWriteRate += p.diskWriteRate
        }
    }
}

/// A bounded load history per container, for the sparklines in lists and
/// the top-containers cards.
public struct ContainerLoadHistory: Sendable {
    public enum Metric: Sendable { case cpu, memory }

    public let capacity: Int
    public private(set) var series: [String: [ContainerLoadPoint]] = [:]

    public init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
    }

    /// Appends one point per container. Containers that are not in `points`
    /// are gone or stopped, so their history is dropped.
    public mutating func record(_ points: [String: ContainerLoadPoint]) {
        series = series.filter { points[$0.key] != nil }
        for (id, point) in points {
            var values = series[id] ?? []
            values.append(point)
            if values.count > capacity { values.removeFirst(values.count - capacity) }
            series[id] = values
        }
    }

    public mutating func removeAll() { series = [:] }

    public func latest(_ id: String) -> ContainerLoadPoint? { series[id]?.last }

    public func history(_ id: String) -> [ContainerLoadPoint] { series[id] ?? [] }

    /// The containers with the highest latest value, highest first. Ties
    /// sort by id so the order is stable between refreshes.
    public func top(by metric: Metric, limit: Int) -> [(id: String, point: ContainerLoadPoint)] {
        let latest = series.compactMap { id, values in values.last.map { (id: id, point: $0) } }
        let sorted = latest.sorted { a, b in
            let va = value(a.point, metric), vb = value(b.point, metric)
            return va == vb ? a.id < b.id : va > vb
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    private func value(_ point: ContainerLoadPoint, _ metric: Metric) -> Double {
        switch metric {
        case .cpu: point.cpuPercent
        case .memory: Double(point.memoryBytes)
        }
    }
}

/// Latest, average and peak of a series, for chart captions and
/// accessibility values.
public struct MetricSummary: Sendable, Hashable {
    public let latest: Double
    public let average: Double
    public let peak: Double

    public init?(_ values: [Double]) {
        guard let last = values.last else { return nil }
        latest = last
        average = values.reduce(0, +) / Double(values.count)
        peak = values.max() ?? last
    }

    /// A rounded upper bound for a dynamic chart domain: at least `minimum`,
    /// and 20 % above the peak so the line does not touch the top.
    public static func domainUpperBound(_ values: [Double], minimum: Double) -> Double {
        max((values.max() ?? 0) * 1.2, minimum)
    }
}
