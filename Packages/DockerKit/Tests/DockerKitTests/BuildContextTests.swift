import Foundation
import Testing
@testable import DockerKit

/// Covers the tar-context packing and `.dockerignore` filtering that back a
/// Docker daemon `/build` upload.
struct BuildContextTests {
    /// Writes a small tree under a fresh temporary directory and returns its URL.
    private func makeContext(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gantry-build-\(UUID().uuidString)")
        let fm = FileManager.default
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test func packsContentsAtArchiveRoot() throws {
        let context = try makeContext([
            "Dockerfile": "FROM scratch\n",
            "app/main.go": "package main\n"
        ])
        defer { try? FileManager.default.removeItem(at: context) }

        let tar = try TarWriter.archiveDirectoryContents(context)
        let names = Set(TarReader.entries(in: tar).map(\.name))

        // No enclosing directory component — the Dockerfile sits at the root.
        #expect(names.contains("Dockerfile"))
        #expect(names.contains("app/main.go"))
        #expect(!names.contains { $0.hasPrefix(context.lastPathComponent) })
    }

    @Test func dockerignoreExcludesMatchedPaths() throws {
        let context = try makeContext([
            "Dockerfile": "FROM scratch\n",
            "keep.txt": "x",
            "node_modules/dep/index.js": "y",
            "build/out.tmp": "z",
            ".dockerignore": "node_modules\nbuild\n"
        ])
        defer { try? FileManager.default.removeItem(at: context) }

        let ignore = DockerIgnore.load(contextDirectory: context)
        let tar = try TarWriter.archiveDirectoryContents(context, ignore: ignore)
        let names = Set(TarReader.entries(in: tar).map(\.name))

        #expect(names.contains("Dockerfile"))
        #expect(names.contains("keep.txt"))
        #expect(!names.contains("node_modules/dep/index.js"))
        // The ignored directory is pruned entirely.
        #expect(!names.contains { $0.hasPrefix("node_modules") })
        #expect(!names.contains { $0.hasPrefix("build") })
    }

    @Test func buildQueryEncodesSpecParameters() {
        let spec = ImageBuildSpec(
            contextPath: "/tmp/ctx",
            dockerfile: "docker/Dockerfile.prod",
            tag: "myapp:1.0",
            buildArgs: ["VERSION": "1.0", "ENV": "prod"],
            target: "runtime",
            labels: ["team": "core"],
            noCache: true
        )
        let query = DockerClient.buildQuery(spec)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        #expect(value("t") == "myapp:1.0")
        #expect(value("dockerfile") == "docker/Dockerfile.prod")
        #expect(value("target") == "runtime")
        #expect(value("nocache") == "1")
        #expect(value("rm") == "1")
        // Maps are JSON with sorted keys.
        #expect(value("buildargs") == #"{"ENV":"prod","VERSION":"1.0"}"#)
        #expect(value("labels") == #"{"team":"core"}"#)
    }

    @Test func buildQueryOmitsEmptyOptionals() {
        let spec = ImageBuildSpec(contextPath: "/tmp/ctx", tag: "bare:latest")
        let query = DockerClient.buildQuery(spec)
        let names = Set(query.map(\.name))
        #expect(names.contains("t"))
        #expect(names.contains("rm"))
        #expect(!names.contains("dockerfile"))
        #expect(!names.contains("buildargs"))
        #expect(!names.contains("labels"))
        #expect(!names.contains("target"))
        #expect(!names.contains("nocache"))
    }

    @Test func splitPreservingNewlinesKeepsTerminators() {
        let lines = DockerClient.splitPreservingNewlines("Step 1\nStep 2\ntrailing")
        #expect(lines == ["Step 1\n", "Step 2\n", "trailing"])
        #expect(DockerClient.splitPreservingNewlines("").isEmpty)
    }
}
