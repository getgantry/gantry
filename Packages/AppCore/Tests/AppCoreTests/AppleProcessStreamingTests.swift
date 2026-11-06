import Foundation
import Testing
@testable import AppCore

/// The streamed CLI paths, driven by `/bin/sh` in place of the `container`
/// binary (`cliOverride` accepts any executable).
@Suite struct AppleProcessStreamingTests {
    @Test func streamContainerDeliversEveryLineInOrder() async throws {
        let script = "i=0; while [ $i -lt 3000 ]; do echo line $i; i=$((i+1)); done; echo tail >&2"
        var lines: [String] = []
        for try await line in AppleContainerControl.streamContainer(["-c", script], cliOverride: "/bin/sh") {
            lines.append(line)
        }
        #expect(lines == (0..<3000).map { "line \($0)" } + ["tail"])
    }

    @Test func streamContainerThrowsOnDeathBySignal() async throws {
        let stream = AppleContainerControl.streamContainer(["-c", "echo started; kill -9 $$"], cliOverride: "/bin/sh")
        var lines: [String] = []
        do {
            for try await line in stream { lines.append(line) }
            Issue.record("a killed process must not finish as a success")
        } catch let error as AppleControlError {
            #expect(error.localizedDescription.contains("signal 9"))
        }
        #expect(lines == ["started"])
    }

    @Test func streamContainerConsumerCancelEndsQuietly() async throws {
        let started = Date()
        let task = Task {
            var count = 0
            for try await _ in AppleContainerControl.streamContainer(["-c", "echo one; sleep 30"], cliOverride: "/bin/sh") {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func createClusterDeliversAllLinesBeforeItReturns() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-cluster-\(UUID().uuidString).sh")
        try "i=0; while [ $i -lt 2000 ]; do echo node $i; i=$((i+1)); done; printf 'last'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let lines = LineLog()
        try await AppleContainerControl.createCluster(
            .init(name: "gantry-fix-test"),
            command: script.path,
            cliOverride: "/bin/sh",
            output: { lines.append($0) }
        )
        #expect(lines.all == (0..<2000).map { "node \($0)" } + ["last"])
    }

    @Test func createClusterReportsDeathBySignal() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("gantry-cluster-\(UUID().uuidString).sh")
        try "echo booting; kill -9 $$\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        await #expect(throws: AppleControlError.self) {
            try await AppleContainerControl.createCluster(
                .init(name: "gantry-fix-test"),
                command: script.path,
                cliOverride: "/bin/sh"
            )
        }
    }

    @Test func runPassesInputAndKeepsLargeOutput() async throws {
        let input = String(repeating: "0123456789abcdef\n", count: 40_000)
        let result = await AppleContainerControl.run("/bin/cat", [], input: Data(input.utf8))
        #expect(result.exitCode == 0)
        #expect(result.stdout == input)
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
