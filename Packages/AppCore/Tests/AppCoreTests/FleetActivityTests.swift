import Foundation
import Testing
import DockerKit
@testable import AppCore

@Suite("FleetActivity")
struct FleetActivityTests {
    private let hostA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let hostB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func container(
        _ id: String, state: String = "running", status: String = "Up 3 hours",
        image: String = "alpine:latest", labels: [String: String] = [:]
    ) throws -> ContainerSummary {
        let object: [String: Any] = [
            "Id": id, "Names": ["/\(id)"], "Image": image, "State": state, "Status": status, "Labels": labels,
        ]
        return try JSONDecoder().decode(ContainerSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func point(cpu: Double, memory: Int64 = 0, network: Double = 0, disk: Double = 0) -> ContainerLoadPoint {
        ContainerLoadPoint(
            date: .now, cpuPercent: cpu, memoryBytes: memory,
            networkInRate: network, networkOutRate: 0, diskReadRate: 0, diskWriteRate: disk
        )
    }

    private func row(
        _ name: String, host: String = "Alpha", hostID: UUID? = nil, image: String = "alpine",
        cpu: Double? = nil, memory: Int64 = 0, uptime: TimeInterval? = nil
    ) -> FleetActivity.Row {
        FleetActivity.Row(
            hostID: hostID ?? hostA, hostName: host, isAppleContainer: false,
            containerID: name, name: name, image: image,
            load: cpu.map { point(cpu: $0, memory: memory) }, uptime: uptime
        )
    }

    // MARK: Snapshot

    @Test func snapshotHasRunningVisibleContainersOfConnectedHosts() throws {
        let hosts = [
            FleetActivity.HostInput(
                id: hostA, name: "Local", isAppleContainer: true, state: .connected,
                containers: [
                    try container("web"),
                    try container("old", state: "exited", status: "Exited (0) 2 hours ago"),
                    try container("buildkit", labels: ["com.apple.container.resource.role": "builder"]),
                    try container("gantry-debug-web"),
                    try container("paused", state: "paused", status: "Up 2 hours (Paused)"),
                ],
                load: ["web": point(cpu: 12, memory: 1024)]
            ),
            FleetActivity.HostInput(
                id: hostB, name: "Remote", isAppleContainer: false, state: .connected,
                containers: [try container("web", status: "Up About a minute")],
                load: [:]
            ),
        ]
        let snapshot = FleetActivity.snapshot(hosts: hosts)
        #expect(snapshot.rows.map(\.id) == [
            FleetActivity.Row.makeID(hostID: hostA, containerID: "web"),
            FleetActivity.Row.makeID(hostID: hostB, containerID: "web"),
        ])
        #expect(snapshot.rows[0].cpuPercent == 12)
        #expect(snapshot.rows[0].memoryBytes == 1024)
        #expect(snapshot.rows[0].uptime == 10_800)
        #expect(snapshot.rows[0].isAppleContainer)
        #expect(snapshot.rows[1].load == nil)
        #expect(snapshot.rows[1].uptime == 60)
        #expect(snapshot.connectedHostCount == 2)
        #expect(snapshot.unavailableHosts.isEmpty)
    }

    @Test func unavailableHostsKeepOrderAndReason() throws {
        let c = UUID()
        let hosts = [
            FleetActivity.HostInput(id: hostA, name: "Down", isAppleContainer: false,
                                    state: .failed("Connection refused"), containers: [try container("x")], load: [:]),
            FleetActivity.HostInput(id: hostB, name: "Up", isAppleContainer: false,
                                    state: .connected, containers: [try container("y")], load: [:]),
            FleetActivity.HostInput(id: c, name: "Wait", isAppleContainer: false,
                                    state: .connecting, containers: [], load: [:]),
        ]
        let snapshot = FleetActivity.snapshot(hosts: hosts)
        #expect(snapshot.rows.map(\.name) == ["y"])
        #expect(snapshot.unavailableHosts.map(\.name) == ["Down", "Wait"])
        #expect(snapshot.unavailableHosts[0].state == .failed("Connection refused"))
        #expect(snapshot.unavailableHosts[0].state.canRetry)
        #expect(!snapshot.unavailableHosts[1].state.canRetry)
        #expect(FleetActivity.HostState.disconnected.canRetry)
        #expect(snapshot.connectedHostCount == 1)
    }

    @Test func hostStateFromConnectionStatus() {
        #expect(FleetActivity.HostState(.failed("x")) == .failed("x"))
        #expect(FleetActivity.HostState(.connecting) == .connecting)
        #expect(FleetActivity.HostState(.disconnected) == .disconnected)
    }

    // MARK: Sort

    @Test func cpuSortsHighestFirstByDefaultAndReverses() {
        let rows = [row("a", cpu: 5), row("b", cpu: 50), row("c", cpu: 20)]
        #expect(FleetActivity.sorted(rows, using: []).map(\.name) == ["b", "c", "a"])
        let ascending = FleetActivity.Comparator(.cpu, order: .forward)
        #expect(FleetActivity.sorted(rows, using: [ascending]).map(\.name) == ["a", "c", "b"])
    }

    @Test(arguments: [SortOrder.forward, .reverse])
    func rowsWithoutValueAreLastInBothOrders(order: SortOrder) {
        let rows = [row("none"), row("low", cpu: 1), row("high", cpu: 9), row("also-none")]
        let sorted = FleetActivity.sorted(rows, using: [FleetActivity.Comparator(.cpu, order: order)])
        #expect(Array(sorted.map(\.name).suffix(2)) == ["also-none", "none"])
    }

    @Test(arguments: FleetActivity.Column.allCases)
    func everyColumnSortsBothWaysWithStableTies(column: FleetActivity.Column) {
        let rows = [
            row("b", host: "Beta", hostID: hostB, image: "redis", cpu: 2, memory: 20, uptime: 20),
            row("a", host: "Alpha", image: "nginx", cpu: 1, memory: 10, uptime: 10),
            row("c", host: "Alpha", image: "postgres", cpu: 3, memory: 30, uptime: 30),
        ]
        let forward = FleetActivity.sorted(rows, using: [FleetActivity.Comparator(column, order: .forward)])
        let reverse = FleetActivity.sorted(rows, using: [FleetActivity.Comparator(column, order: .reverse)])
        #expect(forward.count == 3)
        if column == .host {
            // Alpha twice: the tie sorts by name A to Z in both orders.
            #expect(forward.map(\.name) == ["a", "c", "b"])
            #expect(reverse.map(\.name) == ["b", "a", "c"])
        } else if column == .network || column == .disk {
            // All zero: the order is the tie order.
            #expect(forward.map(\.name) == ["a", "c", "b"])
            #expect(reverse.map(\.name) == ["a", "c", "b"])
        } else {
            #expect(forward.map(\.name) == reverse.map(\.name).reversed())
        }
    }

    @Test func tiesSortByHostThenNameThenID() {
        let rows = [
            row("web", host: "Beta", hostID: hostB, cpu: 1),
            row("api", host: "Beta", hostID: hostB, cpu: 1),
            row("web", host: "Alpha", cpu: 1),
        ]
        for order in [SortOrder.forward, .reverse] {
            let sorted = FleetActivity.sorted(rows, using: [FleetActivity.Comparator(.cpu, order: order)])
            #expect(sorted.map { "\($0.hostName)/\($0.name)" } == ["Alpha/web", "Beta/api", "Beta/web"])
        }
    }

    @Test func textColumnsUseNaturalOrder() {
        let rows = [row("web10"), row("web2"), row("Web1")]
        let sorted = FleetActivity.sorted(rows, using: [FleetActivity.Comparator(.name)])
        #expect(sorted.map(\.name) == ["Web1", "web2", "web10"])
    }

    @Test func defaultOrders() {
        #expect(FleetActivity.Comparator(.name).order == .forward)
        #expect(FleetActivity.Comparator(.memory).order == .reverse)
        #expect(FleetActivity.Column(rawValue: "uptime") == .uptime)
    }

    // MARK: Filter

    @Test func textFilterMatchesNameImageAndHostInAnyCase() {
        let rows = [
            row("cache", host: "Alpha", image: "redis:7"),
            row("REDIS-proxy", host: "Alpha", image: "envoy"),
            row("db", host: "Rédis box", hostID: hostB, image: "postgres"),
            row("web", host: "Alpha", image: "nginx"),
        ]
        let filter = FleetActivity.Filter(text: "  redis ")
        #expect(filter.apply(rows).map(\.name) == ["cache", "REDIS-proxy", "db"])
        #expect(FleetActivity.Filter().apply(rows).count == 4)
        #expect(!FleetActivity.Filter(text: "  ").isActive)
    }

    @Test func hostAndTextFiltersCombine() {
        let rows = [
            row("redis", host: "Alpha"),
            row("redis", host: "Beta", hostID: hostB),
            row("web", host: "Beta", hostID: hostB),
        ]
        let filter = FleetActivity.Filter(text: "red", hostID: hostB)
        #expect(filter.apply(rows).map(\.id) == [FleetActivity.Row.makeID(hostID: hostB, containerID: "redis")])
    }

    @Test func removedHostResetsTheHostFilter() {
        let filter = FleetActivity.Filter(text: "x", hostID: hostB)
        #expect(filter.pruned(hostIDs: [hostA]) == FleetActivity.Filter(text: "x"))
        #expect(filter.pruned(hostIDs: [hostA, hostB]) == filter)
    }
}
