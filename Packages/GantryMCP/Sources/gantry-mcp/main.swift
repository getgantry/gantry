import Foundation
import MCP

// Gantry MCP server: exposes the local and trusted-SSH Docker hosts Gantry
// manages as Model Context Protocol tools over stdio.

let tools = GantryTools()

let server = Server(
    name: "gantry",
    version: "1.0.0",
    title: "Gantry Docker",
    instructions: """
    Gantry exposes Docker hosts (the local daemon and SSH remotes already \
    trusted in the Gantry app) as tools. Call list_hosts first to discover \
    host ids, then pass a host_id to the other tools. List tools default to \
    all hosts when host_id is omitted. SSH hosts are reachable headlessly only \
    if their host key was already trusted and any required secret is in the \
    Keychain.
    """,
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: await tools.toolDefinitions())
}

await server.withMethodHandler(CallTool.self) { params in
    await tools.call(name: params.name, arguments: params.arguments)
}

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
await tools.shutdown()
