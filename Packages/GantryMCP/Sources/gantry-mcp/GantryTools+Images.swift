import Foundation
import MCP
import DockerKit

/// Image management tools: pull, build, tag, remove, history, inspect, prune.
/// Streaming operations (pull, build) run to completion and return the final
/// status with a bounded tail of the progress log.
extension GantryTools {
    func imageTools() -> [Tool] {
        let hostIDRequired = Schema.string("Gantry host id (UUID, from list_hosts).")
        let imageProp = Schema.string("Image id or reference (repo:tag).")
        return [
            Tool(
                name: "pull_image",
                description: "Pull an image by reference (runs to completion). Returns the final status and a tail of progress. Public registries only.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "reference": Schema.string("Image reference, e.g. nginx:alpine or ghcr.io/owner/app:tag.")
                ], required: ["host_id", "reference"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: true)
            ),
            Tool(
                name: "build_image",
                description: "Build an image from a local context directory (runs to completion). Works on local Docker, SSH and apple/container.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "context_path": Schema.string("Absolute path to the build context directory on this Mac."),
                    "tag": Schema.string("Tag for the built image, e.g. myapp:latest."),
                    "dockerfile": Schema.string("Dockerfile path relative to the context (default Dockerfile)."),
                    "build_args": .object(["type": .string("object"), "description": .string("--build-arg values as a string→string map.")]),
                    "target": Schema.string("Target build stage (optional)."),
                    "no_cache": Schema.boolean("Skip the build cache (default false).")
                ], required: ["host_id", "context_path", "tag"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "tag_image",
                description: "Add a repo:tag to an existing image.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "image_id": imageProp,
                    "repo": Schema.string("Target repository."),
                    "tag": Schema.string("Target tag.")
                ], required: ["host_id", "image_id", "repo", "tag"]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
            ),
            Tool(
                name: "remove_image",
                description: "Delete an image.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "image_id": imageProp,
                    "force": Schema.boolean("Force removal (default false).")
                ], required: ["host_id", "image_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            ),
            Tool(
                name: "image_history",
                description: "Return an image's layer history (newest first).",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "image_id": imageProp
                ], required: ["host_id", "image_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "inspect_image",
                description: "Return the full raw JSON inspect of an image.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired, "image_id": imageProp
                ], required: ["host_id", "image_id"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "prune_images",
                description: "Remove unused images. By default only dangling (untagged) images; set dangling=false to remove all unused.",
                inputSchema: Schema.object(properties: [
                    "host_id": hostIDRequired,
                    "dangling": Schema.boolean("Only dangling images (default true).")
                ], required: ["host_id"]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, openWorldHint: false)
            )
        ]
    }

    func handleImages(_ name: String, _ args: Arguments) async throws -> CallTool.Result? {
        switch name {
        case "pull_image":    return try await pullImage(args)
        case "build_image":   return try await buildImage(args)
        case "tag_image":     return try await tagImage(args)
        case "remove_image":  return try await removeImage(args)
        case "image_history": return try await imageHistory(args)
        case "inspect_image": return try await inspectImage(args)
        case "prune_images":  return try await pruneImages(args)
        default:              return nil
        }
    }

    // MARK: - Implementations

    private func pullImage(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let reference = try args.requiredString("reference")
        let client = try await docker.connect(to: host)

        let stream = try await client.pullImage(reference: reference, auth: nil)
        var lines: [String] = []
        for try await progress in stream {
            let status = progress.status
            if !status.isEmpty { lines.append(status) }
        }
        let tail = lines.suffix(20).joined(separator: "\n")
        return .text("OK: pulled \(reference) on \(host.name).\n\(tail)")
    }

    private func buildImage(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let contextPath = try args.requiredString("context_path")
        let tag = try args.requiredString("tag")
        let client = try await docker.connect(to: host)

        let spec = ImageBuildSpec(
            contextPath: contextPath,
            dockerfile: args.string("dockerfile"),
            tag: tag,
            buildArgs: args.stringDict("build_args"),
            target: args.string("target"),
            noCache: args.bool("no_cache", default: false)
        )
        var lines: [String] = []
        var imageID: String?
        for try await line in try await client.buildImageStream(spec) {
            if !line.text.isEmpty { lines.append(line.text) }
            if let id = line.imageID { imageID = id }
        }
        let tail = lines.suffix(20).joined(separator: "\n")
        let idText = imageID.map { " (image \($0))" } ?? ""
        return .text("OK: built \(tag)\(idText) on \(host.name).\n\(cap(tail, bytes: 50 * 1024))")
    }

    private func tagImage(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("image_id")
        let repo = try args.requiredString("repo")
        let tag = try args.requiredString("tag")
        let client = try await docker.connect(to: host)
        try await client.tagImage(id: id, repo: repo, tag: tag)
        return .text("OK: tagged \(id) as \(repo):\(tag).")
    }

    private func removeImage(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("image_id")
        let client = try await docker.connect(to: host)
        try await client.removeImage(id: id, force: args.bool("force", default: false))
        return .text("OK: removed image \(id).")
    }

    private func imageHistory(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("image_id")
        let client = try await docker.connect(to: host)
        let history = try await client.imageHistory(id: id)
        return .text(try jsonText(history))
    }

    private func inspectImage(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let id = try args.requiredString("image_id")
        let client = try await docker.connect(to: host)
        let data = try await client.rawInspectImage(id: id)
        return .text(cap(String(decoding: data, as: UTF8.self), bytes: 200 * 1024))
    }

    private func pruneImages(_ args: Arguments) async throws -> CallTool.Result {
        let host = try requiredHost(args)
        let client = try await docker.connect(to: host)
        let result = try await client.pruneImages(dangling: args.bool("dangling", default: true))
        return .text(pruneText(result, noun: "images"))
    }
}
