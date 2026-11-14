import Foundation
import Testing
import MCP
import DockerKit
import AppCore
@testable import gantry_mcp

@Suite("fleet_activity")
struct FleetActivityToolTests {
    private let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func container(_ id: String, status: String = "Up 2 hours") throws -> ContainerSummary {
        try decodeJSON(ContainerSummary.self, """
            {"Id":"\(id)","Names":["/\(id)"],"Image":"alpine","State":"running","Status":"\(status)"}
            """)
    }

    private func input(_ load: [String: ContainerLoadPoint]) throws -> FleetActivity.HostInput {
        FleetActivity.HostInput(
            id: hostID, name: "Local", isAppleContainer: true, state: .connected,
            containers: [try container("small"), try container("big"), try container("new", status: "Up")],
            load: load
        )
    }

    @Test func toolIsInCatalogAndReadOnly() async {
        let tool = await GantryTools().toolDefinitions().first { $0.name == "fleet_activity" }
        #expect(tool?.annotations.readOnlyHint == true)
    }

    @Test func requestDefaultsAndClamps() throws {
        let defaults = try FleetActivityRequest(Arguments(nil))
        #expect(defaults.comparator == FleetActivity.Comparator(.cpu, order: .reverse))
        #expect(defaults.limit == 50)
        let custom = try FleetActivityRequest(Arguments([
            "sort": .string("Name"), "ascending": .bool(false), "limit": .int(0),
        ]))
        #expect(custom.comparator == FleetActivity.Comparator(.name, order: .reverse))
        #expect(custom.limit == 1)
        #expect(try FleetActivityRequest(Arguments(["limit": .int(9999)])).limit == 500)
    }

    @Test func unknownSortColumnIsAToolError() async {
        let result = await GantryTools().call(name: "fleet_activity", arguments: ["sort": .string("pids")])
        #expect(result.isErrorResult)
        #expect(result.text.contains("Unknown sort column 'pids'"))
    }

    @Test func unknownHostIsAToolError() async {
        let result = await GantryTools().call(name: "fleet_activity", arguments: ["host_id": .string(UUID().uuidString)])
        #expect(result.isErrorResult)
        #expect(result.text.contains("No host with id"))
    }

    @Test func reportSortsByMemoryAndCutsToTheLimit() throws {
        let load = [
            "small": ContainerLoadPoint(date: .now, cpuPercent: 50, memoryBytes: 10, networkInRate: 1.4),
            "big": ContainerLoadPoint(date: .now, cpuPercent: 1.23456, memoryBytes: 900),
        ]
        let request = try FleetActivityRequest(Arguments(["sort": .string("memory"), "limit": .int(2)]))
        let errors = [FleetActivityReport.HostError(hostID: "x", hostName: "Remote", error: "refused")]
        let report = FleetActivityReport.make(hosts: [try input(load)], errors: errors, request: request, sampledSeconds: 1)
        #expect(report.containers.map(\.name) == ["big", "small"])
        #expect(report.containers[0].cpuPercent == 1.23)
        #expect(report.containers[0].uptimeSeconds == 7200)
        #expect(report.containers[1].networkInBytesPerSecond == 1)
        #expect(report.errors == errors)
    }

    @Test func containerWithoutSampleHasNoMetricsAndSortsLast() throws {
        let load = ["small": ContainerLoadPoint(date: .now, cpuPercent: 5, memoryBytes: 10)]
        let request = try FleetActivityRequest(Arguments(["ascending": .bool(true)]))
        let report = FleetActivityReport.make(hosts: [try input(load)], errors: [], request: request, sampledSeconds: 1)
        #expect(report.containers.first?.name == "small")
        let unsampled = try #require(report.containers.first { $0.name == "new" })
        #expect(unsampled.cpuPercent == nil)
        #expect(unsampled.uptimeSeconds == nil)
        let json = try jsonText(report)
        #expect(!json.contains("\"uptimeSeconds\" : null"))
    }
}
