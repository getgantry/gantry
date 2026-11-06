import Foundation
import Testing
@testable import DockerKit

/// A temporary file of `size` bytes with line structure, so a reorder or a
/// lost chunk changes the content.
private func makeFixture(size: Int) throws -> (URL, Data) {
    var text = ""
    var line = 0
    while text.utf8.count < size {
        text += String(format: "line %08d abcdefghijklmnopqrstuvwxyz\n", line)
        line += 1
    }
    let data = Data(text.utf8)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gantry-child-\(UUID().uuidString).txt")
    try data.write(to: url)
    return (url, data)
}

@Test func childProcessKeepsStdoutAndStderrApart() async throws {
    let (url, expected) = try makeFixture(size: 300 * 1024)
    defer { try? FileManager.default.removeItem(at: url) }
    for _ in 0..<40 {
        let result = try await ChildProcess.run(
            "/bin/sh",
            ["-c", "cat \"$1\"; cat \"$1\" >&2; cat \"$1\"; cat \"$1\" >&2", "sh", url.path]
        )
        #expect(result.exit.succeeded)
        #expect(result.stdout == expected + expected)
        #expect(result.stderr == expected + expected)
    }
}

/// 200 runs of `cat` on 400 KB, 8 at a time: every output must be exact.
@Test func childProcessOutputIsByteExactUnderStress() async throws {
    let (url, expected) = try makeFixture(size: 400 * 1024)
    defer { try? FileManager.default.removeItem(at: url) }
    var bad = 0
    try await withThrowingTaskGroup(of: Bool.self) { group in
        var started = 0
        while started < 8 {
            group.addTask { try await ChildProcess.run("/bin/cat", [url.path]).stdout == expected }
            started += 1
        }
        while let ok = try await group.next() {
            if !ok { bad += 1 }
            if started < 200 {
                group.addTask { try await ChildProcess.run("/bin/cat", [url.path]).stdout == expected }
                started += 1
            }
        }
    }
    #expect(bad == 0)
}

@Test func childProcessWritesInputAndMergesEnvironment() async throws {
    let input = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let echoed = try await ChildProcess.run("/bin/cat", [], input: input)
    #expect(echoed.stdout == input)

    let env = try await ChildProcess.run(
        "/bin/sh",
        ["-c", "printf '%s|%s' \"$GANTRY_CHILD_TEST\" \"$HOME\""],
        environment: ["GANTRY_CHILD_TEST": "value"]
    )
    #expect(env.stdoutText == "value|\(NSHomeDirectory())")
}

@Test func childProcessIgnoresAnUnreadInput() async throws {
    // The child exits before it reads: the write must fail quietly (no SIGPIPE).
    let result = try await ChildProcess.run("/usr/bin/true", [], input: Data(count: 4 << 20))
    #expect(result.exit.succeeded)
}

@Test func childProcessReportsDeathBySignal() async throws {
    let result = try await ChildProcess.run("/bin/sh", ["-c", "echo before; kill -9 $$"])
    #expect(result.exit.signaled)
    #expect(result.exit.status == 9)
    #expect(!result.exit.succeeded)
    #expect(result.stdoutText == "before\n")
}

@Test func childProcessCancellationTerminatesTheProcess() async throws {
    let started = Date()
    let task = Task { try await ChildProcess.run("/bin/sleep", ["30"]) }
    try await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func childProcessTerminateBeforeStartPreventsTheLaunch() throws {
    let child = ChildProcess(executable: "/usr/bin/touch", arguments: ["/nonexistent-gantry"])
    child.terminate()
    #expect(throws: CancellationError.self) {
        try child.start(output: { _ in }, completion: { _ in })
    }
}

@Test func childProcessMergedOutputComesAsStdout() async throws {
    let child = ChildProcess(
        executable: "/bin/sh",
        arguments: ["-c", "echo out; echo err >&2"],
        mergeOutput: true
    )
    let text: String = try await withCheckedThrowingContinuation { continuation in
        let buffer = StderrBuffer()
        do {
            try child.start(output: { chunk in
                if case .stdout(let data) = chunk { buffer.append(data) }
            }, completion: { _ in continuation.resume(returning: buffer.text) })
        } catch {
            continuation.resume(throwing: error)
        }
    }
    #expect(text == "out\nerr\n")
}

private extension ChildProcessResult {
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}
