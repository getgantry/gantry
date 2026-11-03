import Foundation

/// One node of a `container cluster` Kubernetes cluster (apple/container 1.5+).
/// Each node is a container that runs the kindest/node image.
public struct ContainerClusterNode: Identifiable, Hashable, Sendable {
    /// The node (container) name, for example `dev` or `dev-worker-1`.
    public var name: String
    /// `control-plane`, `worker`, or a comma-separated list for a dual-role node.
    public var role: String
    public var state: String
    public var cpus: Int
    /// Memory in MiB, as the CLI reports it.
    public var memoryMB: Int
    /// IPv4 addresses, comma-separated.
    public var address: String
    /// Published ports as comma-separated `host->container` pairs.
    public var ports: String

    public var id: String { name }

    public init(
        name: String,
        role: String,
        state: String,
        cpus: Int = 0,
        memoryMB: Int = 0,
        address: String = "",
        ports: String = ""
    ) {
        self.name = name
        self.role = role
        self.state = state
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.address = address
        self.ports = ports
    }

    public var roles: [String] {
        role.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var isControlPlane: Bool { roles.contains("control-plane") }
    public var isRunning: Bool { state.lowercased() == "running" }
    public var memoryBytes: Int64 { Int64(memoryMB) * 1_048_576 }
}

/// A local Kubernetes cluster from `container cluster create` (`container k8s`
/// on CLI 1.5.0 to 1.6.0). The CLI has no JSON output for clusters, so the
/// model comes from the `cluster list` table.
public struct ContainerCluster: Identifiable, Hashable, Sendable {
    public var name: String
    /// Control-plane nodes first, then workers.
    public var nodes: [ContainerClusterNode]

    public var id: String { name }

    public init(name: String, nodes: [ContainerClusterNode]) {
        self.name = name
        self.nodes = nodes
    }

    public var controlPlane: ContainerClusterNode? { nodes.first(where: \.isControlPlane) }
    public var workers: [ContainerClusterNode] { nodes.filter { !$0.isControlPlane } }
    public var isRunning: Bool { !nodes.isEmpty && nodes.allSatisfy(\.isRunning) }

    /// The shared node state, or `degraded` when the nodes do not agree.
    public var state: String {
        let states = Set(nodes.map { $0.state.lowercased() })
        if states.count == 1, let only = states.first { return only }
        return states.isEmpty ? "unknown" : "degraded"
    }

    /// The CLI names the kubeconfig context, cluster and user after the cluster.
    public var kubectlContext: String { name }

    /// The host port that forwards to the API server, from a `6445->6443` entry.
    public var apiServerPort: Int? {
        guard let ports = controlPlane?.ports else { return nil }
        for pair in ports.split(separator: ",") {
            let sides = pair.components(separatedBy: "->")
            if sides.count == 2, sides[1].trimmingCharacters(in: .whitespaces).hasPrefix("6443") {
                return Int(sides[0].trimmingCharacters(in: .whitespaces).split(separator: ":").last ?? "")
            }
        }
        return nil
    }

    public var apiServerURL: String? { apiServerPort.map { "https://127.0.0.1:\($0)" } }

    /// `~/.kube/<name>.kubeconfig`, the path that the CLI help uses.
    public static func defaultKubeconfigPath(for name: String, home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".kube/\(name).kubeconfig")
    }

    /// The container networks in `container inspect` JSON of the nodes, in
    /// first-seen order. Reads `status.networks`, then `configuration.networks`.
    public static func networkNames(fromInspectJSON data: Data) -> [String] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var names: [String] = []
        for item in items {
            let status = (item["status"] as? [String: Any])?["networks"] as? [[String: Any]]
            let configured = (item["configuration"] as? [String: Any])?["networks"] as? [[String: Any]]
            for network in status ?? configured ?? [] {
                if let name = network["network"] as? String, !name.isEmpty, !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    // MARK: - Parsing

    /// Parses the `container cluster list` table. The CLI pads each column to
    /// its longest cell, so header offsets keep empty cells and the `2048 MB`
    /// cell in place. Without a known header, rows are split on spaces.
    public static func parseList(_ output: String) -> [ContainerCluster] {
        let lines = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let headerIndex = lines.firstIndex(where: isHeader) else {
            return group(lines.compactMap(parseLoose))
        }
        let columns = columnStarts(lines[headerIndex])
        let rows = lines[(headerIndex + 1)...].compactMap { parseRow($0, columns: columns) }
        return group(rows)
    }

    private static func isHeader(_ line: String) -> Bool {
        let words = line.split(separator: " ").map(String.init)
        return words.first == "CLUSTER" && words.contains("NODE")
    }

    /// The character offset where each named column starts.
    private static func columnStarts(_ header: String) -> [String: Int] {
        var result: [String: Int] = [:]
        let chars = Array(header)
        var index = 0
        while index < chars.count {
            if chars[index] == " " { index += 1; continue }
            let start = index
            while index < chars.count, chars[index] != " " { index += 1 }
            result[String(chars[start..<index])] = start
        }
        return result
    }

    private struct Row {
        var cluster: String
        var node: ContainerClusterNode
    }

    private static func parseRow(_ line: String, columns: [String: Int]) -> Row? {
        let chars = Array(line)
        let ordered = columns.sorted { $0.value < $1.value }
        var cells: [String: String] = [:]
        for (offset, column) in ordered.enumerated() {
            let start = column.value
            let end = offset + 1 < ordered.count ? ordered[offset + 1].value : chars.count
            guard start < chars.count else { cells[column.key] = ""; continue }
            cells[column.key] = String(chars[start..<min(end, chars.count)]).trimmingCharacters(in: .whitespaces)
        }
        // A cell wider than its column means the table is not aligned.
        guard let cluster = cells["CLUSTER"], !cluster.isEmpty, !cluster.contains(" "),
              let name = cells["NODE"], !name.isEmpty, !name.contains(" "),
              let cpus = cells["CPUS"], cpus.isEmpty || Int(cpus) != nil else {
            return parseLoose(line)
        }
        return Row(cluster: cluster, node: ContainerClusterNode(
            name: name,
            role: cells["ROLE"] ?? "",
            state: cells["STATE"] ?? "",
            cpus: Int(cpus) ?? 0,
            memoryMB: parseMemoryMB(cells["MEMORY"] ?? ""),
            address: cells["ADDR"] ?? "",
            ports: cells["PORTS"] ?? ""
        ))
    }

    /// Cluster, node, role, state, CPUs, memory, then optional address and ports.
    private static func parseLoose(_ line: String) -> Row? {
        var words = line.split(separator: " ").map(String.init)
        guard words.count >= 4, words.first != "CLUSTER" else { return nil }
        if words.count >= 7, Int(words[5]) != nil, ["MB", "MIB", "GB", "GIB"].contains(words[6].uppercased()) {
            words[5] += " " + words[6]
            words.remove(at: 6)
        }
        func word(_ index: Int) -> String { index < words.count ? words[index] : "" }
        return Row(cluster: words[0], node: ContainerClusterNode(
            name: words[1],
            role: word(2),
            state: word(3),
            cpus: Int(word(4)) ?? 0,
            memoryMB: parseMemoryMB(word(5)),
            address: word(6),
            ports: word(7)
        ))
    }

    /// Reads `2048 MB` (the CLI form), `2 GB` or a bare number as MiB.
    static func parseMemoryMB(_ text: String) -> Int {
        let parts = text.split(separator: " ")
        guard let value = parts.first.flatMap({ Int($0) }) else { return 0 }
        let unit = parts.count > 1 ? parts[1].uppercased() : "MB"
        return unit.hasPrefix("G") ? value * 1024 : value
    }

    private static func group(_ rows: [Row]) -> [ContainerCluster] {
        var order: [String] = []
        var nodes: [String: [ContainerClusterNode]] = [:]
        for row in rows {
            if nodes[row.cluster] == nil { order.append(row.cluster) }
            nodes[row.cluster, default: []].append(row.node)
        }
        return order.map { name in
            let members = nodes[name] ?? []
            let sorted = members.filter(\.isControlPlane) + members.filter { !$0.isControlPlane }
            return ContainerCluster(name: name, nodes: sorted)
        }
    }
}

/// A `container cluster create` status line, such as
/// `[3/5] Joining worker dev-worker-1 [1m 2s]`. The CLI prints one about once
/// a second, with log lines between the steps.
public struct ClusterCreateProgress: Sendable, Equatable {
    public var step: Int
    public var total: Int
    /// The step text without the counter and the elapsed time.
    public var message: String
    /// The elapsed time as the CLI prints it, for example `1m 2s`.
    public var elapsed: String?

    public init(step: Int, total: Int, message: String, elapsed: String? = nil) {
        self.step = step
        self.total = total
        self.message = message
        self.elapsed = elapsed
    }

    public var fraction: Double { total > 0 ? min(1, Double(step) / Double(total)) : 0 }

    /// Parses a status line, or returns nil for any other line.
    public static func parse(_ line: String) -> ClusterCreateProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /\[(\d+)\/(\d+)\]\s*(.*?)\s*(?:\[([^\]]*)\])?/),
              let step = Int(match.1), let total = Int(match.2) else { return nil }
        return ClusterCreateProgress(
            step: step,
            total: total,
            message: String(match.3),
            elapsed: match.4.map(String.init)
        )
    }
}
