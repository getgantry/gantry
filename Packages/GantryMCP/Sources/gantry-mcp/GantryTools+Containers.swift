import Foundation
import MCP
import DockerKit

/// Container management tools beyond the core list/lifecycle set: create, rename,
/// commit, restart policy, processes, inspect, prune, and file access.
extension GantryTools {
    func containerTools() -> [Tool] {
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        let containerProp = Schema.string("Container id or name.")
        return [
            Tool(
                name: "create_container",
                description: "Create (and by default start) a container from an image. Ports map container→host as {\"80/tcp\": \"8080\"}; env is [\"KEY=value\"]; binds are [\"/host:/container[:ro]\"].",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "image": Schema.string("Image reference, e.g. nginx:alpine."),
                    "name": Schema.string("Container name (optional)."),
                    "cmd": .object(["type": .string("array"), "description": .string("Command override, as an argv array."), "items": .object(["type": .string("string")])]),
                    "env": .object(["type": .string("array"), "description": .string("Environment as KEY=value strings."), "items": .object(["type": .string("string")])]),
                    "ports": .object(["type": .string("object"), "description": .string("Port map, container port/proto → host port, e.g. {\"80/tcp\":\"8080\"}.")]),
                    "binds": .object(["type": .string("array"), "description": .string("Bind mounts, host:container[:ro]."), "items": .object(["type": .string("string")])]),
                    "labels": .object(["type": .string("object"), "description": .string("Labels as a string→string map.")]),
                    "restart_policy": Schema.string("Restart policy: no, always, unless-stopped, on-failure (default no)."),
                    "start": Schema.boolean("Start the container after creating it (default true).")
                ], required: ["host_id", "image"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "rename_container",
                description: "Rename a container.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "name": Schema.string("New container name.")
                ], required: ["host_id", "container_id", "name"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "commit_container",
                description: "Commit a container's current state to a new image.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "repo": Schema.string("Image repository, e.g. myapp."),
                    "tag": Schema.string("Image tag, e.g. latest."),
                    "comment": Schema.string("Optional commit comment.")
                ], required: ["host_id", "container_id", "repo", "tag"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "update_restart_policy",
                description: "Change a container's restart policy.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "policy": Schema.string("Restart policy.", enumValues: ["no", "always", "unless-stopped", "on-failure"]),
                    "max_retries": Schema.integer("Max retries for on-failure (default 0).")
                ], required: ["host_id", "container_id", "policy"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "container_processes",
                description: "List the running processes inside a container (docker top).",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp
                ], required: ["host_id", "container_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "inspect_container",
                description: "Return the full raw JSON inspect of a container.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp
                ], required: ["host_id", "container_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "prune_containers",
                description: "Remove all stopped containers on a host.",
                inputSchema: Schema.object(properties: ["host_id": hostIDRequired], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_list_files",
                description: "List the immediate contents of a directory inside a container.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "path": Schema.string("Absolute path of the directory inside the container.")
                ], required: ["host_id", "container_id", "path"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_read_file",
                description: "Read a file from inside a container. Returns up to 200KB of text (binary files reported, not decoded).",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "path": Schema.string("Absolute path of the file inside the container.")
                ], required: ["host_id", "container_id", "path"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "container_write_file",
                description: "Write a text file inside a container, creating or overwriting it.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "container_id": containerProp,
                    "path": Schema.string("Absolute path of the file to write inside the container."),
                    "content": Schema.string("UTF-8 text content to write.")
                ], required: ["host_id", "container_id", "path", "content"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            )
        ]
    }

    func handleContainers(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "create_container":      return try await createContainer(args)
        case "rename_container":      return try await renameContainer(args)
        case "commit_container":      return try await commitContainer(args)
        case "update_restart_policy": return try await updateRestartPolicy(args)
        case "container_processes":   return try await containerProcesses(args)
        case "inspect_container":     return try await inspectContainer(args)
        case "prune_containers":      return try await pruneContainers(args)
        case "container_list_files":  return try await containerListFiles(args)
        case "container_read_file":   return try await containerReadFile(args)
        case "container_write_file":  return try await containerWriteFile(args)
        default:                      return nil
        }
    }

    // MARK: - Implementations

    private func createContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let image = try args.requiredString("image")
        let client = try await docker.connect(to: host)

        let cmd = args.stringArray("cmd")
        let config = ContainerCreateRequest(
            image: image,
            cmd: cmd.isEmpty ? nil : cmd,
            env: args.stringArray("env"),
            ports: args.stringDict("ports"),
            binds: args.stringArray("binds"),
            restartPolicy: args.string("restart_policy") ?? "no",
            labels: args.stringDict("labels"),
            name: args.string("name")
        )
        let id = try await client.createContainer(config: config, name: args.string("name"))
        let start = args.bool("start", default: true)
        if start { try await client.startContainer(id: id) }
        return .text("OK: created \(start ? "and started " : "")container \(id) on \(host.name).")
    }

    private func renameContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let newName = try args.requiredString("name")
        let client = try await docker.connect(to: host)
        try await client.renameContainer(id: id, to: newName)
        return .text("OK: renamed \(id) to \(newName).")
    }

    private func commitContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let repo = try args.requiredString("repo")
        let tag = try args.requiredString("tag")
        let client = try await docker.connect(to: host)
        let imageID = try await client.commitContainer(id: id, repo: repo, tag: tag, comment: args.string("comment"))
        return .text("OK: committed \(id) to \(repo):\(tag) (image \(imageID)).")
    }

    private func updateRestartPolicy(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let policy = try args.requiredString("policy")
        let client = try await docker.connect(to: host)
        try await client.updateRestartPolicy(id: id, policy: policy, maxRetries: args.int("max_retries", default: 0))
        return .text("OK: restart policy of \(id) set to \(policy).")
    }

    private func containerProcesses(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let client = try await docker.connect(to: host)
        let top = try await client.containerProcesses(id: id)
        return .text(try jsonText(top))
    }

    private func inspectContainer(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let client = try await docker.connect(to: host)
        let data = try await client.rawInspectContainer(id: id)
        return .text(cap(String(decoding: data, as: UTF8.self), bytes: 200 * 1024))
    }

    private func pruneContainers(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let result = try await client.pruneContainers()
        return .text(pruneText(result, noun: "containers"))
    }

    private func containerListFiles(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let path = try args.requiredString("path")
        let client = try await docker.connect(to: host)
        // Prefer the fast exec-based listing; fall back to the tar archive when
        // the container has no usable shell.
        let entries: [ContainerFileEntry]
        do {
            entries = try await client.listDirectoryFast(containerID: id, path: path)
        } catch {
            entries = try await client.listDirectory(containerID: id, path: path)
        }
        return .text(try jsonText(entries.map(FileEntryDTO.init)))
    }

    private func containerReadFile(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let path = try args.requiredString("path")
        let client = try await docker.connect(to: host)

        let stream = try await client.downloadArchive(containerID: id, path: path)
        var buffer = Data()
        let limit = 200 * 1024
        for try await chunk in stream.bytes {
            buffer.append(chunk)
            if buffer.count > limit + 1_048_576 { break } // tar overhead headroom
        }
        guard let payload = TarReader.firstFilePayload(in: buffer) else {
            throw ToolError("No file found at \(path) (is it a directory?).")
        }
        // Treat as text unless it contains NUL bytes.
        if payload.contains(0) {
            return .text("[binary file, \(payload.count) bytes — not decoded]")
        }
        let text = String(decoding: payload, as: UTF8.self)
        return .text(cap(text, bytes: limit))
    }

    private func containerWriteFile(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("container_id")
        let path = try args.requiredString("path")
        let content = try args.requiredString("content")
        let client = try await docker.connect(to: host)

        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let dir = url.deletingLastPathComponent().path
        let tar = TarWriter.archive(entries: [
            TarEntry(name: fileName, data: Data(content.utf8))
        ])
        try await client.uploadArchive(containerID: id, path: dir.isEmpty ? "/" : dir, tar: tar)
        return .text("OK: wrote \(content.utf8.count) bytes to \(path) in \(id).")
    }
}
