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

    // MARK: - Property edits

    /// What `listProperties` returns: schema keys plus reported keys.
    private var sampleProperties: [AppleSystemProperty] {
        let schema = AppleContainerControl.propertySchema.map { AppleSystemProperty(key: $0.key, kind: $0.kind) }
        let reported = [
            AppleSystemProperty(key: "custom.flag", kind: .unknown, effective: .bool(true)),
            AppleSystemProperty(key: "custom.ratio", kind: .unknown, effective: .number(0.5)),
            AppleSystemProperty(key: "custom.count", kind: .unknown, effective: .integer(3)),
            AppleSystemProperty(key: "custom.ports", kind: .unknown, effective: .other("[1, 2]")),
            AppleSystemProperty(key: "custom.names", kind: .unknown, effective: .strings(["a"]))
        ]
        return schema + reported
    }

    @Test func acceptsKnownPropertyKeys() throws {
        let properties = sampleProperties
        #expect(try GantryTools.editablePropertyKind("build.cpus", in: properties, clearing: false) == .count)
        #expect(try GantryTools.editablePropertyKind("dns.domain", in: properties, clearing: false) == .domain)
        // In the schema, not set anywhere.
        #expect(try GantryTools.editablePropertyKind("kernel.url", in: properties, clearing: false) == .url)
        // Unknown to the schema: the reported type.
        #expect(try GantryTools.editablePropertyKind("custom.flag", in: properties, clearing: false) == .bool)
        #expect(try GantryTools.editablePropertyKind("custom.ratio", in: properties, clearing: false) == .numberValue)
        #expect(try GantryTools.editablePropertyKind("custom.count", in: properties, clearing: false) == .integerValue)
        #expect(throws: AppleSystemError.self) { try AppleContainerControl.validatedPropertyValue("lots", kind: .integerValue) }
        #expect(throws: AppleSystemError.self) { try AppleContainerControl.validatedPropertyValue("maybe", kind: .bool) }
    }

    @Test func refusesTyposAndInjectedKeys() {
        let properties = sampleProperties
        let keys = [
            "build.cpu", "nothing.here", "cpus", "build.cpus\n[kernel]\nbinaryPath = \"x\"",
            "build\n[kernel]\nbinaryPath = \"x\"\n[z.y.cpus", "build.cpus]", "[build].cpus",
            "build.\"cpus\"", "build.cpus = 1", "build.cpus #", "build. cpus"
        ]
        for key in keys {
            #expect(throws: ToolError.self, "\(key.debugDescription)") {
                try GantryTools.editablePropertyKind(key, in: properties, clearing: false)
            }
            #expect(throws: ToolError.self, "\(key.debugDescription)") {
                try GantryTools.editablePropertyKind(key, in: properties, clearing: true)
            }
        }
    }

    @Test func refusesOverwritingArrays() throws {
        let properties = sampleProperties
        #expect(throws: ToolError.self) {
            try GantryTools.editablePropertyKind("custom.ports", in: properties, clearing: false)
        }
        // Clearing the user value is still allowed.
        _ = try GantryTools.editablePropertyKind("custom.ports", in: properties, clearing: true)
    }

    @Test func editsStringLists() throws {
        let properties = sampleProperties
        #expect(try GantryTools.editablePropertyKind("container.dns.nameservers", in: properties, clearing: false) == .nameserverList)
        #expect(try GantryTools.editablePropertyKind("custom.names", in: properties, clearing: false) == .stringList)
        let value = try AppleContainerControl.validatedPropertyValue("1.1.1.1, 8.8.8.8", kind: .nameserverList)
        #expect(value == .strings(["1.1.1.1", "8.8.8.8"]))
        #expect(value.tomlLiteral == "[\"1.1.1.1\", \"8.8.8.8\"]")
        #expect(throws: AppleSystemError.self) { try AppleContainerControl.validatedPropertyValue("dns.google", kind: .nameserverList) }
    }

    @Test func valuesCannotInjectLines() {
        for value in ["4\n[kernel]", "x\"\n[a]", "1\r\nb = 2"] {
            #expect(throws: AppleSystemError.self) { try AppleContainerControl.validatedPropertyValue(value, kind: .string) }
        }
        // Quotes and brackets on one line stay inside the TOML string.
        #expect(AppleSystemPropertyValue.string("a\"] [b").tomlLiteral == "\"a\\\"] [b\"")
    }
}
