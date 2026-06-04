import Foundation
import Testing
import MCP
import AppCore
@testable import gantry_mcp

/// Tests for the tool catalog and the dispatch/validation paths that do NOT
/// require a Docker daemon (unknown tools, missing/invalid arguments, unknown
/// host ids). These exercise the LocalizedError-unwrapping error mapping.
@Suite("GantryTools")
struct GantryToolsTests {

    // MARK: - Tool catalog

    @Test func toolCatalogHasExpectedTools() async {
        let tools = await GantryTools().toolDefinitions()
        let names = Set(tools.map(\.name))
        #expect(names == [
            "list_hosts", "list_containers", "container_action",
            "container_logs", "container_stats", "container_exec",
            "list_images", "list_volumes", "list_networks", "system_df"
        ])
    }

    @Test func everyToolHasNonEmptyDescriptionAndSchema() async {
        let tools = await GantryTools().toolDefinitions()
        for tool in tools {
            #expect(!(tool.description ?? "").isEmpty, "\(tool.name) missing description")
            // inputSchema is a non-optional Value; assert it is an object schema.
            if case .object = tool.inputSchema {} else {
                Issue.record("\(tool.name) schema is not an object")
            }
        }
    }

    @Test func destructiveToolsAreAnnotated() async {
        let tools = await GantryTools().toolDefinitions()
        let action = tools.first { $0.name == "container_action" }
        #expect(action?.annotations.destructiveHint == true)
        let listHosts = tools.first { $0.name == "list_hosts" }
        #expect(listHosts?.annotations.readOnlyHint == true)
    }

    // MARK: - Dispatch: unknown tool

    @Test func unknownToolReturnsError() async {
        let result = await GantryTools().call(name: "no_such_tool", arguments: nil)
        #expect(result.isErrorResult)
        #expect(result.text.contains("Unknown tool 'no_such_tool'."))
    }

    // MARK: - Dispatch: argument validation (no daemon required)

    @Test func containerActionMissingHostIDReturnsError() async {
        // No host_id at all -> requiredHost throws "Missing required 'host_id'".
        let result = await GantryTools().call(
            name: "container_action",
            arguments: ["container_id": .string("x"), "action": .string("start")]
        )
        #expect(result.isErrorResult)
        #expect(result.text.contains("host_id"))
    }

    @Test func containerActionInvalidHostIDReturnsError() async {
        let result = await GantryTools().call(
            name: "container_action",
            arguments: ["host_id": .string("not-a-uuid"), "container_id": .string("x"), "action": .string("start")]
        )
        #expect(result.isErrorResult)
        #expect(result.text.contains("valid host id"))
    }

    @Test func containerActionUnknownHostIDReturnsError() async {
        let randomID = UUID().uuidString
        let result = await GantryTools().call(
            name: "container_action",
            arguments: ["host_id": .string(randomID), "container_id": .string("x"), "action": .string("start")]
        )
        #expect(result.isErrorResult)
        #expect(result.text.contains("No host with id"))
    }

    @Test func systemDFMissingHostIDReturnsError() async {
        let result = await GantryTools().call(name: "system_df", arguments: [:])
        #expect(result.isErrorResult)
        #expect(result.text.contains("host_id"))
    }

    @Test func containerLogsUnknownHostReturnsError() async {
        let result = await GantryTools().call(
            name: "container_logs",
            arguments: ["host_id": .string(UUID().uuidString), "container_id": .string("x")]
        )
        #expect(result.isErrorResult)
        #expect(result.text.contains("No host with id"))
    }

    @Test func containerStatsUnknownHostReturnsError() async {
        let result = await GantryTools().call(
            name: "container_stats",
            arguments: ["host_id": .string(UUID().uuidString), "container_id": .string("x")]
        )
        #expect(result.isErrorResult)
    }

    @Test func containerExecUnknownHostReturnsError() async {
        let result = await GantryTools().call(
            name: "container_exec",
            arguments: ["host_id": .string(UUID().uuidString), "container_id": .string("x"), "command": .string("echo hi")]
        )
        #expect(result.isErrorResult)
    }

    // MARK: - list_hosts always works (reads persisted/synthesised hosts)

    @Test func listHostsReturnsValidJSON() async {
        let result = await GantryTools().call(name: "list_hosts", arguments: nil)
        #expect(!result.isErrorResult)
        let data = Data(result.text.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data)
        #expect(parsed is [Any])
    }

    // MARK: - HeadlessError descriptions

    @Test func headlessErrorDescriptions() {
        #expect(HeadlessError.noSocket.errorDescription?.contains("No Docker socket") == true)
        let id = UUID()
        #expect(HeadlessError.unknownHost(id).errorDescription?.contains(id.uuidString) == true)
        #expect(HeadlessError.credentialsUnavailable.errorDescription?.contains("Keychain") == true)
    }
}
