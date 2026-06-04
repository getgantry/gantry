import Foundation

/// A single decoded sample from `GET /containers/{id}/stats`.
///
/// Decodes Docker's raw snake_case cgroup statistics directly and derives the
/// same CPU / memory percentages the `docker stats` CLI reports.
public struct ContainerStatsSample: Sendable, Hashable, Identifiable, Decodable {
    public let id: UUID
    /// The instant the daemon read these counters (the `read` field).
    public let readAt: Date
    public let cpuPercent: Double
    public let onlineCPUs: Int
    public let memoryUsageBytes: Int64
    public let memoryLimitBytes: Int64
    public let memoryPercent: Double
    public let networkRxBytes: Int64
    public let networkTxBytes: Int64
    public let blockReadBytes: Int64
    public let blockWriteBytes: Int64
    public let pids: Int

    public init(from decoder: Decoder) throws {
        id = UUID()
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // read timestamp
        if let readString = try c.decodeIfPresent(String.self, forKey: .read),
           let date = RFC3339Nano.date(from: readString) {
            readAt = date
        } else {
            readAt = Date()
        }

        // CPU
        let cpuStats = try c.decodeIfPresent(CPUStats.self, forKey: .cpuStats) ?? CPUStats()
        let preCPUStats = try c.decodeIfPresent(CPUStats.self, forKey: .precpuStats) ?? CPUStats()
        let online = cpuStats.onlineCPUs ?? cpuStats.percpuUsage?.count ?? 0
        onlineCPUs = online

        let cpuDelta = cpuStats.cpuUsage.totalUsage - preCPUStats.cpuUsage.totalUsage
        let systemDelta = cpuStats.systemCPUUsage - preCPUStats.systemCPUUsage
        if systemDelta > 0 && cpuDelta > 0 {
            cpuPercent = (Double(cpuDelta) / Double(systemDelta)) * Double(online) * 100.0
        } else {
            cpuPercent = 0
        }

        // Memory
        let memStats = try c.decodeIfPresent(MemoryStats.self, forKey: .memoryStats) ?? MemoryStats()
        let usage = memStats.usage
        let limit = memStats.limit
        let inactive = memStats.stats?.totalInactiveFile
            ?? memStats.stats?.inactiveFile
            ?? memStats.stats?.cache
            ?? 0
        let used = max(usage - inactive, 0)
        memoryUsageBytes = used
        memoryLimitBytes = limit
        memoryPercent = limit > 0 ? (Double(used) / Double(limit)) * 100.0 : 0

        // Network — sum over all interfaces.
        let networks = try c.decodeIfPresent([String: NetworkStats].self, forKey: .networks) ?? [:]
        var rx: Int64 = 0
        var tx: Int64 = 0
        for stats in networks.values {
            rx += stats.rxBytes
            tx += stats.txBytes
        }
        networkRxBytes = rx
        networkTxBytes = tx

        // Block IO — sum Read/Write service bytes.
        let blkio = try c.decodeIfPresent(BlkioStats.self, forKey: .blkioStats) ?? BlkioStats()
        var read: Int64 = 0
        var write: Int64 = 0
        for entry in blkio.ioServiceBytesRecursive {
            switch entry.op.lowercased() {
            case "read": read += entry.value
            case "write": write += entry.value
            default: break
            }
        }
        blockReadBytes = read
        blockWriteBytes = write

        // PIDs
        let pidsStats = try c.decodeIfPresent(PidsStats.self, forKey: .pidsStats) ?? PidsStats()
        pids = pidsStats.current
    }

    enum CodingKeys: String, CodingKey {
        case read
        case cpuStats = "cpu_stats"
        case precpuStats = "precpu_stats"
        case memoryStats = "memory_stats"
        case networks
        case blkioStats = "blkio_stats"
        case pidsStats = "pids_stats"
    }

    // MARK: - Raw nested decoders

    private struct CPUUsage: Decodable {
        var totalUsage: Int64 = 0
        enum CodingKeys: String, CodingKey { case totalUsage = "total_usage" }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalUsage = try c.decodeIfPresent(Int64.self, forKey: .totalUsage) ?? 0
        }
    }

    private struct CPUStats: Decodable {
        var cpuUsage = CPUUsage()
        var systemCPUUsage: Int64 = 0
        var onlineCPUs: Int?
        var percpuUsage: [Int64]?

        enum CodingKeys: String, CodingKey {
            case cpuUsage = "cpu_usage"
            case systemCPUUsage = "system_cpu_usage"
            case onlineCPUs = "online_cpus"
        }
        private enum UsageKeys: String, CodingKey { case percpuUsage = "percpu_usage" }

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cpuUsage = try c.decodeIfPresent(CPUUsage.self, forKey: .cpuUsage) ?? CPUUsage()
            systemCPUUsage = try c.decodeIfPresent(Int64.self, forKey: .systemCPUUsage) ?? 0
            onlineCPUs = try c.decodeIfPresent(Int.self, forKey: .onlineCPUs)
            let usageContainer = try decoder.container(keyedBy: UsageKeys.self)
            percpuUsage = try usageContainer.decodeIfPresent([Int64].self, forKey: .percpuUsage)
        }
    }

    private struct MemoryStats: Decodable {
        var usage: Int64 = 0
        var limit: Int64 = 0
        var stats: MemoryStatsDetail?
        enum CodingKeys: String, CodingKey { case usage, limit, stats }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usage = try c.decodeIfPresent(Int64.self, forKey: .usage) ?? 0
            limit = try c.decodeIfPresent(Int64.self, forKey: .limit) ?? 0
            stats = try c.decodeIfPresent(MemoryStatsDetail.self, forKey: .stats)
        }
    }

    private struct MemoryStatsDetail: Decodable {
        var inactiveFile: Int64?
        var totalInactiveFile: Int64?
        var cache: Int64?
        enum CodingKeys: String, CodingKey {
            case inactiveFile = "inactive_file"
            case totalInactiveFile = "total_inactive_file"
            case cache
        }
    }

    private struct NetworkStats: Decodable {
        var rxBytes: Int64 = 0
        var txBytes: Int64 = 0
        enum CodingKeys: String, CodingKey {
            case rxBytes = "rx_bytes"
            case txBytes = "tx_bytes"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rxBytes = try c.decodeIfPresent(Int64.self, forKey: .rxBytes) ?? 0
            txBytes = try c.decodeIfPresent(Int64.self, forKey: .txBytes) ?? 0
        }
    }

    private struct BlkioStats: Decodable {
        var ioServiceBytesRecursive: [BlkioEntry] = []
        enum CodingKeys: String, CodingKey { case ioServiceBytesRecursive = "io_service_bytes_recursive" }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The field may be null on some platforms.
            ioServiceBytesRecursive = try c.decodeIfPresent([BlkioEntry].self, forKey: .ioServiceBytesRecursive) ?? []
        }
    }

    private struct BlkioEntry: Decodable {
        var op: String = ""
        var value: Int64 = 0
        enum CodingKeys: String, CodingKey { case op = "op", value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decodeIfPresent(String.self, forKey: .op) ?? ""
            value = try c.decodeIfPresent(Int64.self, forKey: .value) ?? 0
        }
    }

    private struct PidsStats: Decodable {
        var current: Int = 0
        enum CodingKeys: String, CodingKey { case current }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            current = try c.decodeIfPresent(Int.self, forKey: .current) ?? 0
        }
    }

}
