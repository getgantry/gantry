import Foundation
import Testing
@testable import DockerKit

// MARK: - Scripted CLI runner

/// Test double for the `container` CLI: returns scripted results matched by
/// argument prefix and records every invocation for argv assertions.
private final class ScriptedCLIRunner: AppleContainerCLIRunning, @unchecked Sendable {
    struct Stub {
        var prefix: [String]
        var result: AppleCLIResult
    }

    private let lock = NSLock()
    private var stubs: [Stub] = []
    private(set) var calls: [[String]] = []
    var streamChunks: [Data] = []
    var streamError: Error?
    var interactiveFactory: (@Sendable ([String], Bool) -> any AppleCLIInteractiveProcess)?

    func stub(_ prefix: [String], stdout: String = "", stderr: String = "", exitCode: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(Stub(prefix: prefix, result: AppleCLIResult(
            exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)
        )))
    }

    func recordedCalls() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func run(_ arguments: [String]) async throws -> AppleCLIResult {
        lock.withLock {
            calls.append(arguments)
            // Later stubs win, so tests can override earlier setup.
            for stub in stubs.reversed() where arguments.starts(with: stub.prefix) {
                return stub.result
            }
            return AppleCLIResult(
                exitCode: 64,
                stdout: Data(),
                stderr: Data("Error: unstubbed invocation: \(arguments.joined(separator: " "))".utf8)
            )
        }
    }

    func stream(_ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        calls.append(arguments)
        let chunks = streamChunks
        let error = streamError
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func interactive(_ arguments: [String], tty: Bool) throws -> any AppleCLIInteractiveProcess {
        lock.lock()
        calls.append(arguments)
        let factory = interactiveFactory
        lock.unlock()
        guard let factory else {
            throw DockerError.connectionFailed("no interactive factory stubbed")
        }
        return factory(arguments, tty)
    }
}

/// Scripted interactive process: replays chunks, records writes/resizes.
/// With `holdExit: true` the process "stays running" until `releaseExit()`,
/// so tests can interact with it before the transport marks it finished.
private final class ScriptedInteractiveProcess: AppleCLIInteractiveProcess, @unchecked Sendable {
    let output: AsyncStream<AppleCLIOutputChunk>
    let exitCode: Int
    private let lock = NSLock()
    private(set) var written: [Data] = []
    private(set) var resizes: [(Int, Int)] = []
    private let exitGate: AsyncStream<Void>
    private let exitGateContinuation: AsyncStream<Void>.Continuation

    init(chunks: [AppleCLIOutputChunk], exitCode: Int = 0, holdExit: Bool = false) {
        self.exitCode = exitCode
        let (stream, continuation) = AsyncStream<AppleCLIOutputChunk>.makeStream()
        output = stream
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()

        (exitGate, exitGateContinuation) = AsyncStream<Void>.makeStream()
        if !holdExit { exitGateContinuation.finish() }
    }

    func releaseExit() {
        exitGateContinuation.finish()
    }

    func write(_ data: Data) async throws {
        lock.withLock { written.append(data) }
    }

    func resize(columns: Int, rows: Int) {
        lock.withLock { resizes.append((columns, rows)) }
    }

    func waitForExit() async -> Int {
        for await _ in exitGate {}
        return exitCode
    }

    func close() async {}
}

private let statusRunningJSON = """
{"apiServerVersion":"container-apiserver version 0.12.3 (build: release, commit: unspeci)","status":"running","apiServerAppName":"container-apiserver"}
"""

private let smokeInspectJSON = """
[{"status":"running","startedDate":802450114.5,"networks":[{"ipv4Address":"192.168.64.2/24","hostname":"gantry-smoke","network":"default"}],"configuration":{"id":"gantry-smoke","image":{"reference":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:5b10","size":1,"mediaType":"x"}},"labels":{},"publishedPorts":[],"initProcess":{"terminal":false,"executable":"sleep","arguments":["600"],"environment":[],"workingDirectory":"/"},"mounts":[],"resources":{"cpus":4,"memoryInBytes":1073741824},"networks":[{"network":"default"}]}}]
"""

/// A connected client/runner pair: negotiate() already performed.
private func makeConnectedClient() async throws -> (DockerClient, ScriptedCLIRunner) {
    let runner = ScriptedCLIRunner()
    runner.stub(["system", "status"], stdout: statusRunningJSON)
    let client = DockerClient(transport: AppleContainerTransport(runner: runner))
    let version = try await client.negotiate()
    #expect(version.version == "0.12.3")
    #expect(version.platformName == "apple/container")
    return (client, runner)
}

// MARK: - Handshake

@Test func appleTransportNegotiateAndPing() async throws {
    let (client, runner) = try await makeConnectedClient()
    try await client.ping()
    #expect(runner.recordedCalls().allSatisfy { $0.starts(with: ["system", "status"]) })
}

@Test func appleTransportStartsStoppedServicesOnConnect() async throws {
    let runner = ScriptedCLIRunner()
    // First status: stopped. After a `system start`, status flips to running.
    runner.stub(["system", "status"], stdout: #"{"status":"stopped","apiServerVersion":""}"#)
    runner.stub(["system", "start"])
    let client = DockerClient(transport: AppleContainerTransport(runner: runner))

    // The transport re-reads status after starting; restub before that read
    // is impossible with a static script, so flip the stub inside `system
    // start` handling: stub order means the LAST matching stub wins — add the
    // running stub after the call happens. Instead, exercise the failure path
    // here (services stay down) and the success path implicitly in
    // `makeConnectedClient` (already running, no start needed).
    await #expect(throws: Error.self) {
        try await client.negotiate()
    }
    let calls = runner.recordedCalls()
    #expect(calls.contains(["system", "start"]))
}

// MARK: - Containers

@Test func appleTransportListsContainers() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["list"], stdout: smokeInspectJSON)
    let containers = try await client.listContainers(all: true)
    #expect(containers.map(\.id) == ["gantry-smoke"])
    #expect(runner.recordedCalls().contains(["list", "--all", "--format", "json"]))
}

@Test func appleTransportContainerLifecycleArgv() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["start"])
    runner.stub(["stop"])
    runner.stub(["kill"])
    runner.stub(["delete"])

    try await client.startContainer(id: "c1")
    try await client.stopContainer(id: "c1", timeout: 10)
    try await client.restartContainer(id: "c1")
    try await client.killContainer(id: "c1", signal: "SIGTERM")
    try await client.removeContainer(id: "c1", force: true)

    let calls = runner.recordedCalls()
    #expect(calls.contains(["start", "c1"]))
    #expect(calls.contains(["stop", "--time", "10", "c1"]))
    // restart = stop + start
    #expect(calls.contains(["stop", "c1"]))
    #expect(calls.filter { $0 == ["start", "c1"] }.count == 2)
    #expect(calls.contains(["kill", "--signal", "SIGTERM", "c1"]))
    #expect(calls.contains(["delete", "--force", "c1"]))
}

@Test func appleTransportInspectContainer() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["inspect", "gantry-smoke"], stdout: smokeInspectJSON)
    let details = try await client.inspectContainer(id: "gantry-smoke")
    #expect(details.displayName == "gantry-smoke")
    #expect(details.state.running)
}

@Test func appleTransportUnsupportedEndpointsThrow501() async throws {
    let (client, _) = try await makeConnectedClient()

    for operation: (DockerClient) async throws -> Void in [
        { try await $0.pauseContainer(id: "c") },
        { try await $0.unpauseContainer(id: "c") },
        { try await $0.renameContainer(id: "c", to: "x") },
        { _ = try await $0.commitContainer(id: "c", repo: "r", tag: "t") },
        { try await $0.updateRestartPolicy(id: "c", policy: "always") },
        { _ = try await $0.imageHistory(id: "i") },
        { try await $0.connectContainer(networkID: "n", containerID: "c") },
        { _ = try await $0.pruneBuildCache() },
        { try await $0.uploadArchive(containerID: "c", path: "/", tar: Data()) }
    ] {
        do {
            try await operation(client)
            Issue.record("expected an unsupported-operation error")
        } catch let DockerError.apiError(status, message) {
            #expect(status == 501)
            #expect(message.contains(AppleContainerTransport.unsupportedMessage))
        }
    }
}

@Test func appleTransportNotFoundMapsTo404() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["start", "ghost"], stderr: "Error: get failed: container ghost not found", exitCode: 1)
    do {
        try await client.startContainer(id: "ghost")
        Issue.record("expected a 404")
    } catch let DockerError.apiError(status, message) {
        #expect(status == 404)
        #expect(message.contains("ghost not found"))
        #expect(!message.hasPrefix("Error:"))
    }
}

@Test func appleTransportCreateContainerBuildsArgv() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["create"], stdout: "fetching...\nweb-1\n")

    let config = ContainerCreateRequest(
        image: "nginx:latest",
        cmd: ["nginx", "-g", "daemon off;"],
        env: ["MODE=prod"],
        ports: ["80/tcp": "8080"],
        binds: ["/tmp/data:/data"],
        restartPolicy: "no",
        tty: true,
        labels: ["app": "web"],
        autoRemove: false,
        name: "web-1"
    )
    let id = try await client.createContainer(config: config, name: "web-1")
    #expect(id == "web-1")

    let create = try #require(runner.recordedCalls().first { $0.first == "create" })
    #expect(create.contains("--name") && create.contains("web-1"))
    #expect(create.contains("--env") && create.contains("MODE=prod"))
    #expect(create.contains("--label") && create.contains("app=web"))
    #expect(create.contains("--tty"))
    #expect(create.contains("--publish") && create.contains("8080:80/tcp"))
    #expect(create.contains("--volume") && create.contains("/tmp/data:/data"))
    // image followed by the command
    let imageIndex = try #require(create.firstIndex(of: "nginx:latest"))
    #expect(Array(create[(imageIndex + 1)...]) == ["nginx", "-g", "daemon off;"])
}

@Test func appleTransportBuildImageArgv() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["build"], stdout: "step 1/3\n", stderr: "")

    let spec = ImageBuildSpec(
        contextPath: "/tmp/myproj/api",
        dockerfile: "Dockerfile.prod",
        tag: "myproj-api:latest",
        buildArgs: ["VERSION": "1.2"],
        target: "runtime",
        labels: ["com.docker.compose.project": "myproj"],
        noCache: true
    )
    _ = try await client.buildImage(spec)

    let build = try #require(runner.recordedCalls().first { $0.first == "build" })
    #expect(build.contains("--tag") && build.contains("myproj-api:latest"))
    #expect(build.contains("--file") && build.contains("Dockerfile.prod"))
    #expect(build.contains("--build-arg") && build.contains("VERSION=1.2"))
    #expect(build.contains("--target") && build.contains("runtime"))
    #expect(build.contains("--label") && build.contains("com.docker.compose.project=myproj"))
    #expect(build.contains("--no-cache"))
    // The context directory is the trailing positional argument.
    #expect(build.last == "/tmp/myproj/api")
}

@Test func appleTransportCreateContainerRejectsRestartPolicy() async throws {
    let (client, _) = try await makeConnectedClient()
    let config = ContainerCreateRequest(image: "alpine", restartPolicy: "always")
    do {
        _ = try await client.createContainer(config: config, name: nil)
        Issue.record("expected a 501 for restart policies")
    } catch let DockerError.apiError(status, _) {
        #expect(status == 501)
    }
}

@Test func appleTransportTopRunsPSInContainer() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(
        ["exec", "c1"],
        stdout: "PID   USER     TIME  COMMAND\n    1 root      0:00 sleep 600\n"
    )
    let top = try await client.containerProcesses(id: "c1")
    #expect(top.titles == ["PID", "USER", "TIME", "COMMAND"])
    #expect(top.processes == [["1", "root", "0:00", "sleep 600"]])
    #expect(runner.recordedCalls().contains(["exec", "c1", "/bin/sh", "-c", "ps aux 2>/dev/null || ps"]))
}

// MARK: - Images

@Test func appleTransportImageDeleteResolvesDigest() async throws {
    let (client, runner) = try await makeConnectedClient()
    let imagesJSON = """
    [{"fullSize":"4,2 MB","reference":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:abc","size":1,"mediaType":"x"}}]
    """
    runner.stub(["image", "list"], stdout: imagesJSON)
    runner.stub(["image", "delete"])

    // The digest comes from a prior list (the UI flow), resolved lazily here.
    try await client.removeImage(id: "sha256:abc", force: true)
    #expect(runner.recordedCalls().contains(
        ["image", "delete", "--force", "docker.io/library/alpine:latest"]
    ))
}

@Test func appleTransportImagePruneVariants() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["image", "prune"], stdout: "sha256:dead\n")

    let dangling = try await client.pruneImages(dangling: true)
    #expect(dangling.deletedCount == 1)
    #expect(runner.recordedCalls().contains(["image", "prune"]))

    _ = try await client.pruneImages(dangling: false)
    #expect(runner.recordedCalls().contains(["image", "prune", "--all"]))
}

@Test func appleTransportTagImage() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["image", "tag"])
    try await client.tagImage(id: "alpine:latest", repo: "mine/alpine", tag: "v1")
    #expect(runner.recordedCalls().contains(["image", "tag", "alpine:latest", "mine/alpine:v1"]))
}

// MARK: - Volumes & networks

@Test func appleTransportVolumeLifecycle() async throws {
    let (client, runner) = try await makeConnectedClient()
    let volumeJSON = """
    [{"name":"data","driver":"local","createdAt":"2026-06-06T14:54:52Z","labels":{},"source":"/x/volume.img","sizeInBytes":1024}]
    """
    runner.stub(["volume", "create"])
    runner.stub(["volume", "inspect", "data"], stdout: volumeJSON)
    runner.stub(["volume", "delete"])
    runner.stub(["volume", "list"], stdout: volumeJSON)
    runner.stub(["volume", "prune"], stdout: "old-vol\n")

    let created = try await client.createVolume(name: "data", driver: "local", labels: ["k": "v"])
    #expect(created.name == "data")
    #expect(runner.recordedCalls().contains(["volume", "create", "--label", "k=v", "data"]))

    let listed = try await client.listVolumes()
    #expect(listed.map(\.name) == ["data"])

    try await client.removeVolume(name: "data")
    #expect(runner.recordedCalls().contains(["volume", "delete", "data"]))

    let pruned = try await client.pruneVolumes()
    #expect(pruned.deletedCount == 1)
}

@Test func appleTransportNetworkLifecycle() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["network", "create"])
    runner.stub(["network", "delete"])
    runner.stub(["network", "list"], stdout: "[]")
    runner.stub(["network", "prune"], stdout: "")

    let id = try await client.createNetwork(name: "backend", driver: "bridge", labels: [:])
    #expect(id == "backend")
    #expect(runner.recordedCalls().contains(["network", "create", "backend"]))

    try await client.removeNetwork(id: "backend")
    #expect(runner.recordedCalls().contains(["network", "delete", "backend"]))

    _ = try await client.pruneNetworks()
    #expect(runner.recordedCalls().contains(["network", "prune"]))
}

// MARK: - Stats

@Test func appleTransportStatsOnceAndDeltas() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(
        ["stats"],
        stdout: #"[{"id":"c1","memoryUsageBytes":1000,"memoryLimitBytes":2000,"cpuUsageUsec":5000,"numProcesses":2,"networkRxBytes":1,"networkTxBytes":2,"blockReadBytes":3,"blockWriteBytes":4}]"#
    )

    let first = try await client.containerStatsOnce(id: "c1")
    #expect(first.memoryUsageBytes == 1000)
    #expect(first.pids == 2)
    #expect(first.cpuPercent == 0)  // no baseline yet

    // The second sample carries precpu from the first; with an unchanged CPU
    // counter the percent stays zero (and is finite, not NaN).
    let second = try await client.containerStatsOnce(id: "c1")
    #expect(second.cpuPercent == 0)
    #expect(second.cpuTotalUsage == 5_000_000)
}

@Test func appleTransportStatsUnknownContainer404() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["stats"], stdout: "[]")
    do {
        _ = try await client.containerStatsOnce(id: "ghost")
        Issue.record("expected 404")
    } catch let DockerError.apiError(status, _) {
        #expect(status == 404)
    }
}

// MARK: - Logs

@Test func appleTransportLogsAreFramedForNonTTY() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["inspect", "gantry-smoke"], stdout: smokeInspectJSON)
    runner.streamChunks = [Data("line one\nline two\n".utf8)]

    let stream = try await client.containerLogs(
        id: "gantry-smoke", tty: false, follow: true, tail: 100
    )
    var lines: [String] = []
    for try await entry in stream {
        lines.append(entry.text)
    }
    #expect(lines == ["line one", "line two"])
    #expect(runner.recordedCalls().contains(["logs", "-n", "100", "--follow", "gantry-smoke"]))
}

// MARK: - Events

@Test func appleTransportEventsUnsupported() async throws {
    let (client, _) = try await makeConnectedClient()
    do {
        _ = try await client.events()
        Issue.record("expected events to be unsupported")
    } catch let DockerError.apiError(status, _) {
        #expect(status == 501)
    }
}

// MARK: - Pull

@Test func appleTransportPullTranslatesProgress() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.streamChunks = [
        Data("[1/2] Fetching image [0s]\r[1/2] Fetching image 50% (...) [1s]\n".utf8),
        Data("[2/2] Unpacking image\n".utf8)
    ]

    let stream = try await client.pullImage(reference: "alpine:3.19")
    var statuses: [String] = []
    var sawPercent = false
    for try await progress in stream {
        statuses.append(progress.status)
        if progress.current == 50 { sawPercent = true }
    }
    #expect(statuses.first == "[1/2] Fetching image [0s]")
    #expect(statuses.last == "Pull complete")
    #expect(sawPercent)
    #expect(runner.recordedCalls().contains(
        ["image", "pull", "alpine:3.19", "--progress", "plain"]
    ))
}

@Test func appleTransportPullFailureSurfacesAsError() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.streamError = DockerError.apiError(status: 500, message: "manifest unknown")

    let stream = try await client.pullImage(reference: "ghost:404")
    do {
        for try await _ in stream {}
        Issue.record("expected the pull stream to throw")
    } catch let DockerError.apiError(_, message) {
        #expect(message.contains("manifest unknown"))
    }
}

// MARK: - Exec

@Test func appleTransportExecFlow() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.interactiveFactory = { _, tty in
        ScriptedInteractiveProcess(
            chunks: tty
                ? [.stdout(Data("shell$ ".utf8))]
                : [.stdout(Data("out\n".utf8)), .stderr(Data("err\n".utf8))],
            exitCode: 0
        )
    }

    // Non-TTY exec: output must arrive in Docker's multiplexed framing.
    let execID = try await client.createExec(
        containerID: "gantry-smoke", command: ["/bin/sh", "-c", "echo out; echo err >&2"], tty: false
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: false)
    let output = try await DockerClient.collectExecLines(from: connection.bytes)
    #expect(output.stdout == "out")
    #expect(output.stderr == "err")

    let inspect = try await client.inspectExec(execID: execID)
    #expect(inspect.running == false)
    #expect(inspect.exitCode == 0)

    let execCall = try #require(runner.recordedCalls().first { $0.first == "exec" })
    #expect(execCall.starts(with: ["exec", "--interactive", "gantry-smoke"]))
    #expect(Array(execCall.suffix(3)) == ["/bin/sh", "-c", "echo out; echo err >&2"])
}

@Test func appleTransportExecTTYPassthroughAndResize() async throws {
    let (client, runner) = try await makeConnectedClient()
    // Hold the exit so the exec is still "running" while the test writes and
    // resizes (a finished exec drops its process and resize becomes a no-op).
    let process = ScriptedInteractiveProcess(chunks: [.stdout(Data("shell$ ".utf8))], holdExit: true)
    runner.interactiveFactory = { _, _ in process }

    let execID = try await client.createExec(
        containerID: "gantry-smoke", command: ["/bin/sh"], tty: true
    )
    let connection = try await client.startExecHijacked(execID: execID, tty: true)

    try await connection.write(Data("ls\n".utf8))
    #expect(process.written == [Data("ls\n".utf8)])

    try await client.resizeExec(execID: execID, width: 120, height: 40)
    #expect(process.resizes.contains { $0 == (120, 40) })

    process.releaseExit()
    var received = Data()
    for try await chunk in connection.bytes {
        received.append(chunk)
    }
    // TTY output is raw — no stdcopy headers.
    #expect(String(decoding: received, as: UTF8.self) == "shell$ ")

    let execCall = try #require(runner.recordedCalls().first { $0.first == "exec" })
    #expect(execCall.contains("--tty"))
}

@Test func appleTransportExecUnknownIDThrows() async throws {
    let (client, _) = try await makeConnectedClient()
    do {
        _ = try await client.startExecHijacked(execID: "ghost", tty: false)
        Issue.record("expected a 404 for the unknown exec id")
    } catch let DockerError.apiError(status, _) {
        #expect(status == 404)
    }
    do {
        _ = try await client.inspectExec(execID: "ghost")
        Issue.record("expected a 404 for the unknown exec id")
    } catch let DockerError.apiError(status, _) {
        #expect(status == 404)
    }
}

// MARK: - System df

@Test func appleTransportSystemDF() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(
        ["system", "df"],
        stdout: #"{"containers":{"active":1,"reclaimable":0,"sizeInBytes":100,"total":1},"images":{"active":1,"reclaimable":50,"sizeInBytes":200,"total":2},"volumes":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0}}"#
    )
    let usage = try await client.systemDF()
    #expect(usage.imagesCount == 2)
    #expect(usage.imagesSize == 200)
    #expect(usage.containersCount == 1)
    #expect(usage.containersSize == 100)
    #expect(runner.recordedCalls().contains(["system", "df", "--format", "json"]))
}

// MARK: - Info

@Test func appleTransportSystemInfo() async throws {
    let (client, runner) = try await makeConnectedClient()
    runner.stub(["list"], stdout: smokeInspectJSON)
    runner.stub(["image", "list"], stdout: "[]")
    let info = try await client.systemInfo()
    #expect(info.containers == 1)
    #expect(info.containersRunning == 1)
    #expect(info.serverVersion == "0.12.3")
    #expect(info.ncpu > 0)
    #expect(info.memTotal > 0)
}

// MARK: - CLI discovery

@Test func appleCLIDiscoveryHonorsOverrideAndEnv() {
    // Explicit override wins when it exists, fails hard when it does not.
    #expect(AppleContainerCLIDiscovery.discover(
        override: "/custom/container", environment: [:], fileExists: { $0 == "/custom/container" }
    ) == "/custom/container")
    #expect(AppleContainerCLIDiscovery.discover(
        override: "/missing/container", environment: [:], fileExists: { _ in false }
    ) == nil)

    // Environment variable comes next.
    #expect(AppleContainerCLIDiscovery.discover(
        environment: ["GANTRY_APPLE_CONTAINER_CLI": "/env/container"],
        fileExists: { $0 == "/env/container" }
    ) == "/env/container")

    // Standard locations last.
    #expect(AppleContainerCLIDiscovery.discover(
        environment: [:], fileExists: { $0 == "/usr/local/bin/container" }
    ) == "/usr/local/bin/container")
    #expect(AppleContainerCLIDiscovery.discover(environment: [:], fileExists: { _ in false }) == nil)
}

@Test func appleCLIErrorMapping() {
    let notFound = AppleContainerCLIError.fromStderr("Error: container x not found", exitCode: 1)
    if case let .apiError(status, message) = notFound {
        #expect(status == 404)
        #expect(message == "container x not found")
    } else {
        Issue.record("expected apiError")
    }

    let generic = AppleContainerCLIError.fromStderr("", exitCode: 7)
    if case let .apiError(status, message) = generic {
        #expect(status == 500)
        #expect(message.contains("status 7"))
    } else {
        Issue.record("expected apiError")
    }
}
