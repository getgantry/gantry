import Foundation
import Testing
import MCP
import AppCore
@testable import gantry_mcp

@Suite("Apple system tools")
struct AppleSystemToolsTests {
    private let names = [
        "apple_system_info", "apple_builder_status", "apple_builder_start", "apple_builder_stop",
        "apple_builder_delete", "apple_list_registries", "apple_registry_logout", "apple_get_properties",
        "apple_set_property", "apple_clear_property", "apple_system_logs", "apple_install_recommended_kernel"
    ]

    @Test func catalogHasAppleSystemTools() async {
        let tools = await GantryTools().toolDefinitions()
        let catalog = Set(tools.map(\.name))
        #expect(Set(names).isSubset(of: catalog))
        let readOnly = ["apple_system_info", "apple_builder_status", "apple_list_registries", "apple_get_properties", "apple_system_logs"]
        for name in readOnly {
            #expect(tools.first { $0.name == name }?.annotations.readOnlyHint == true, "\(name)")
        }
        for name in ["apple_builder_stop", "apple_builder_delete", "apple_registry_logout"] {
            #expect(tools.first { $0.name == name }?.annotations.destructiveHint == true, "\(name)")
        }
    }

    @Test func noToolAcceptsAPassword() async throws {
        let tools = await GantryTools().toolDefinitions()
        #expect(!tools.contains { $0.name.contains("login") })
        for tool in tools {
            let schema = try JSONEncoder().encode(tool.inputSchema)
            let text = String(decoding: schema, as: UTF8.self).lowercased()
            #expect(!text.contains("\"password\""), "\(tool.name) takes a password")
        }
    }

    @Test func toolsRequireHostID() async {
        for name in names {
            let result = await GantryTools().call(name: name, arguments: [:])
            #expect(result.isErrorResult, "\(name)")
            #expect(result.text.contains("host_id"), "\(name): \(result.text)")
        }
    }

    @Test func toolsRejectUnknownHost() async {
        let result = await GantryTools().call(
            name: "apple_get_properties",
            arguments: ["host_id": .string(UUID().uuidString)]
        )
        #expect(result.isErrorResult)
        #expect(result.text.contains("No host with id"))
    }

    @Test func filtersSystemLogs() {
        let info = "2026-11-03 13:57:00.790179+0100 0x1  Info  0x0  1  0    container-apiserver: [c] started"
        let error = "2026-11-03 13:57:01.000000+0100 0x1  Error  0x0  1  0    container-apiserver: [c] failed to start"
        let raw = ["Timestamp  Thread  Type", info, error, info]
        #expect(GantryTools.filterSystemLogs(raw, filter: nil, errorsOnly: false, tail: 200) == [info, error, info])
        #expect(GantryTools.filterSystemLogs(raw, filter: nil, errorsOnly: true, tail: 200) == [error])
        #expect(GantryTools.filterSystemLogs(raw, filter: "FAILED", errorsOnly: false, tail: 200) == [error])
        #expect(GantryTools.filterSystemLogs(raw, filter: nil, errorsOnly: false, tail: 1) == [info])
    }

    @Test func propertyDTO() throws {
        let property = AppleSystemProperty(key: "build.cpus", kind: .count, effective: .integer(2), user: .integer(4))
        let dto = AppleSystemPropertyDTO(property)
        #expect(dto == AppleSystemPropertyDTO(property))
        #expect(dto.value == "2" && dto.userValue == "4" && dto.pendingRestart && dto.kind == "count")
        let json = try jsonText([dto])
        #expect(json.contains("\"pendingRestart\" : true"))
    }
}
