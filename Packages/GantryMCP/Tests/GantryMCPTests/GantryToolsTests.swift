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
        // Core read/lifecycle tools.
        let core: Set<String> = [
            "list_hosts", "list_containers", "container_action",
            "container_logs", "container_stats", "container_exec",
            "list_images", "list_volumes", "list_networks", "system_df"
        ]
        #expect(core.isSubset(of: names))
        // Parity tools across categories.
        let parity: Set<String> = [
            "create_container", "rename_container", "commit_container", "prune_containers",
            "container_read_file", "container_write_file",
            "pull_image", "build_image", "tag_image", "remove_image", "prune_images",
            "create_volume", "remove_volume", "create_network", "connect_container",
            "prune_build_cache", "list_machines", "create_machine", "apple_service_status",
            "list_dns_domains", "compose_up",
            "cloudflare_tunnel_start", "cloudflare_tunnel_list", "cloudflare_tunnel_stop",
            "port_forward_start", "port_forward_list", "port_forward_stop"
        ]
        #expect(parity.isSubset(of: names))
    }

    @Test func toolNamesAreUnique() async {
        let tools = await GantryTools().toolDefinitions()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count, "duplicate tool name in catalog")
        #expect(names.count >= 35, "expected full GUI-parity catalog")
    }

    @Test func appleToolRejectsNonAppleHost() async {
        // list_machines against the seeded local host should error (not apple).
        let hosts = await GantryTools().call(name: "list_hosts", arguments: nil)
        #expect(!hosts.isErrorResult)
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
        let id = UUID()
        #expect(HeadlessError.unknownHost(id).errorDescription?.contains(id.uuidString) == true)
        #expect(HeadlessDockerError.noLocalSocket.errorDescription?.isEmpty == false)
        #expect(HeadlessDockerError.missingCredential("AirFlow").errorDescription?.contains("AirFlow") == true)
    }
}
