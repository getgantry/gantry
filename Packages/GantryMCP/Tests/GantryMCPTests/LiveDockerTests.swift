import Foundation
import Testing
import MCP
import DockerKit
import AppCore
@testable import gantry_mcp

/// Live tests against a real local Docker daemon, gated on socket presence so
/// they no-op on machines without Docker. They exercise the GantryTools dispatch
/// paths, SystemDF parsing, and ExecRunner end-to-end.
///
/// To stay self-contained and to avoid mutating user data, each test that needs
/// a container creates its OWN throwaway container (busybox sleep) via the docker
/// CLI and removes it in a `defer`. No persisted hosts.json is written.
@Suite(.enabled(if: liveSocket != nil))
struct LiveDockerTests {

    // MARK: - docker CLI helpers

    @discardableResult
    private func docker(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Whether the `docker` CLI is usable; some daemons (socket present) may not
    /// have a CLI on PATH. Tests needing containers skip cleanly if not.
    private var dockerCLIAvailable: Bool {
        docker(["version", "--format", "{{.Server.Version}}"]).status == 0
    }

    /// The id of the persisted/synthesised Local host.
    private func localHostID() -> String? {
        let hosts = gantry_mcp.HeadlessDocker().loadHosts()
        return hosts.first(where: { $0.isLocal })?.id.uuidString
    }

    /// Runs `body` with a fresh `GantryTools`, guaranteeing the cached Docker
    /// connections are shut down afterwards (the underlying AsyncHTTPClient
    /// precondition-crashes if a `DockerClient` is dropped without `shutdown()`).
    private func withTools<T>(_ body: (GantryTools) async throws -> T) async rethrows -> T {
        let tools = GantryTools()
        do {
            let result = try await body(tools)
            await tools.shutdown()
            return result
        } catch {
            await tools.shutdown()
            throw error
        }
    }

    /// Starts a throwaway detached busybox container and returns its name.
    private func startThrowaway() -> String? {
        guard dockerCLIAvailable else { return nil }
        let name = "gantry-mcp-test-\(UUID().uuidString.prefix(8))".lowercased()
        // Ensure busybox is present (no-op if cached); ignore pull failures and
        // let the run report the real error.
        _ = docker(["run", "-d", "--name", name, "busybox", "sh", "-c", "echo hello-from-test; sleep 120"])
        let inspect = docker(["inspect", "-f", "{{.State.Running}}", name])
        guard inspect.status == 0 else {
            _ = docker(["rm", "-f", name])
            return nil
        }
        return name
    }

    private func removeThrowaway(_ name: String) {
        _ = docker(["rm", "-f", name])
    }

    // MARK: - Read-only tools (no container needed)

    @Test func listContainersLocalHost() async throws {
        let id = try #require(localHostID())
        try await withTools { tools in
            let result = await tools.call(
                name: "list_containers",
                arguments: ["host_id": .string(id), "all": .bool(true)]
            )
            #expect(!result.isErrorResult)
            // Valid JSON array of ContainerListDTO.
            let arr = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]]
            let local = arr?.first { $0["hostID"] as? String == id }
            #expect(local != nil)
            // The local host connected (no error string).
            #expect(local?["error"] == nil || (local?["error"] is NSNull))
        }
    }

    @Test func listImagesLocalHost() async throws {
        let id = try #require(localHostID())
        try await withTools { tools in
            let result = await tools.call(name: "list_images", arguments: ["host_id": .string(id)])
            #expect(!result.isErrorResult)
            let arr = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]]
            #expect(arr?.first?["error"] == nil || (arr?.first?["error"] is NSNull))
        }
    }

    @Test func listVolumesLocalHost() async throws {
        let id = try #require(localHostID())
        await withTools { tools in
            let result = await tools.call(name: "list_volumes", arguments: ["host_id": .string(id)])
            #expect(!result.isErrorResult)
        }
    }

    @Test func listNetworksLocalHost() async throws {
        let id = try #require(localHostID())
        await withTools { tools in
            let result = await tools.call(name: "list_networks", arguments: ["host_id": .string(id)])
            #expect(!result.isErrorResult)
            // bridge network is always present.
            #expect(result.text.contains("bridge"))
        }
    }

    @Test func systemDFParsesLocalHost() async throws {
        let id = try #require(localHostID())
        try await withTools { tools in
            let result = await tools.call(name: "system_df", arguments: ["host_id": .string(id)])
            #expect(!result.isErrorResult)
            let obj = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
            // SystemDF parsing populated each category dictionary.
            #expect(obj?["images"] is [String: Any])
            #expect(obj?["containers"] is [String: Any])
            #expect(obj?["volumes"] is [String: Any])
            #expect(obj?["buildCacheBytes"] != nil)
        }
    }

    // MARK: - Container lifecycle + logs + stats + exec

    @Test(.timeLimit(.minutes(2)))
    func execLogsStatsAndActionOnThrowawayContainer() async throws {
        guard let name = startThrowaway() else {
            // Docker CLI unavailable: nothing to do, treat as skipped.
            return
        }
        defer { removeThrowaway(name) }

        let id = try #require(localHostID())
        try await withTools { tools in
            // container_exec: run an innocuous command, expect exit 0 and stdout.
            let exec = await tools.call(
                name: "container_exec",
                arguments: ["host_id": .string(id), "container_id": .string(name), "command": .string("echo exec-marker-123 && true")]
            )
            #expect(!exec.isErrorResult, "exec failed: \(exec.text)")
            let execObj = try JSONSerialization.jsonObject(with: Data(exec.text.utf8)) as? [String: Any]
            #expect((execObj?["stdout"] as? String)?.contains("exec-marker-123") == true)
            #expect(execObj?["exitCode"] as? Int == 0)

            // container_exec non-zero exit code.
            let execFail = await tools.call(
                name: "container_exec",
                arguments: ["host_id": .string(id), "container_id": .string(name), "command": .string("exit 7")]
            )
            #expect(!execFail.isErrorResult)
            let failObj = try JSONSerialization.jsonObject(with: Data(execFail.text.utf8)) as? [String: Any]
            #expect(failObj?["exitCode"] as? Int == 7)

            // container_logs: the startup echo should appear.
            let logs = await tools.call(
                name: "container_logs",
                arguments: ["host_id": .string(id), "container_id": .string(name), "tail": .int(50)]
            )
            #expect(!logs.isErrorResult, "logs failed: \(logs.text)")
            #expect(logs.text.contains("hello-from-test"))

            // container_stats: a running container yields one sample.
            let stats = await tools.call(
                name: "container_stats",
                arguments: ["host_id": .string(id), "container_id": .string(name)]
            )
            #expect(!stats.isErrorResult, "stats failed: \(stats.text)")
            let statsObj = try JSONSerialization.jsonObject(with: Data(stats.text.utf8)) as? [String: Any]
            #expect(statsObj?["containerID"] as? String == name)
            #expect(statsObj?["pids"] != nil)

            // container_action: stop the container, then it should no longer be running.
            let stop = await tools.call(
                name: "container_action",
                arguments: ["host_id": .string(id), "container_id": .string(name), "action": .string("stop")]
            )
            #expect(!stop.isErrorResult, "stop failed: \(stop.text)")
            #expect(stop.text.contains("OK: stop"))

            // container_action with an invalid action -> error mapped from ToolError.
            let badAction = await tools.call(
                name: "container_action",
                arguments: ["host_id": .string(id), "container_id": .string(name), "action": .string("frobnicate")]
            )
            #expect(badAction.isErrorResult)
            #expect(badAction.text.contains("Unknown action"))

            // container_action: start it again to exercise the start branch.
            let start = await tools.call(
                name: "container_action",
                arguments: ["host_id": .string(id), "container_id": .string(name), "action": .string("start")]
            )
            #expect(!start.isErrorResult, "start failed: \(start.text)")
        }
    }

    @Test func execMultiLineOutput() async throws {
        // Exercises ExecRunner's stdout demux/join over multiple lines. Stays
        // well under the 30s/200KB caps to keep the suite fast.
        guard let name = startThrowaway() else { return }
        defer { removeThrowaway(name) }

        let id = try #require(localHostID())
        try await withTools { tools in
            let result = await tools.call(
                name: "container_exec",
                arguments: ["host_id": .string(id), "container_id": .string(name), "command": .string("printf 'line1\\nline2\\n'")]
            )
            #expect(!result.isErrorResult)
            let obj = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
            #expect((obj?["stdout"] as? String)?.contains("line1") == true)
            #expect((obj?["stdout"] as? String)?.contains("line2") == true)
        }
    }
}
