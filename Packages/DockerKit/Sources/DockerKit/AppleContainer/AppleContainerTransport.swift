import Foundation
import Darwin

/// `DockerTransport` backed by the apple/container CLI.
///
/// apple/container exposes no Docker-compatible REST API — its CLI talks XPC
/// to `container-apiserver`. This transport keeps the rest of the app intact
/// by accepting the same `DockerRequest`s the real daemon would receive,
/// invoking the CLI, and synthesizing Docker Engine API responses (via
/// `AppleContainerJSON`). Endpoints the platform genuinely lacks answer
/// `501` with a clear message; the UI additionally hides those features.
public actor AppleContainerTransport: DockerTransport {
    public static let unsupportedMessage = "Not supported by apple/container hosts"

    private let runner: any AppleContainerCLIRunning

    /// Pending/running exec instances created via `POST /containers/{id}/exec`.
    private struct ExecState {
        var containerID: String
        var command: [String]
        var tty: Bool
        var process: (any AppleCLIInteractiveProcess)?
        var running = false
        var exitCode: Int?
    }

    private var execs: [String: ExecState] = [:]

    /// Cache of the last `image list` JSON, for digest → reference resolution.
    private var lastImagesList: Data?

    /// Per-container previous synthesized CPU counters, so streamed stats
    /// samples carry `precpu_stats` and decode to a meaningful CPU%.
    private var statsBaselines: [String: (cpuTotal: Int64, system: Int64)] = [:]

    public init(runner: any AppleContainerCLIRunning) {
        self.runner = runner
    }

    /// Convenience: discovers the CLI on disk. Returns nil when not installed.
    public init?(cliPathOverride: String? = nil) {
        guard let path = AppleContainerCLIDiscovery.discover(override: cliPathOverride) else {
            return nil
        }
        self.init(runner: AppleContainerProcessRunner(executablePath: path))
    }

    public func shutdown() async {
        for (id, state) in execs {
            if let process = state.process { await process.close() }
            execs[id] = nil
        }
    }

    // MARK: - CLI plumbing

    /// Runs the CLI, mapping a non-zero exit to a Docker-style `apiError`.
    @discardableResult
    private func cli(_ arguments: [String]) async throws -> AppleCLIResult {
        let result = try await runner.run(arguments)
        guard result.exitCode == 0 else {
            throw AppleContainerCLIError.fromStderr(result.stderrText, exitCode: result.exitCode)
        }
        return result
    }

    private static func ok(_ body: Data = Data(), status: Int = 200) -> DockerResponse {
        DockerResponse(status: status, headers: [:], body: body)
    }

    private static func unsupported(_ what: String) -> DockerError {
        .apiError(status: 501, message: "\(what): \(unsupportedMessage)")
    }

    /// Strips the `/v1.x` prefix and splits the path into components.
    static func route(for path: String) -> [String] {
        var components = path.split(separator: "/").map(String.init)
        if let first = components.first, first.hasPrefix("v"),
           first.dropFirst().contains(".") {
            components.removeFirst()
        }
        return components
    }

    private static func query(_ request: DockerRequest, _ name: String) -> String? {
        request.query.first { $0.name == name }?.value
    }

    private static func boolQuery(_ request: DockerRequest, _ name: String) -> Bool {
        query(request, name) == "true" || query(request, name) == "1"
    }

    // MARK: - Host facts

    private static func hostCPUCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &value, &size, nil, 0)
        return Int(max(value, 1))
    }

    private static func hostMemoryBytes() -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return value
    }

    // MARK: - Execute (buffered request/response)

    public func execute(_ request: DockerRequest) async throws -> DockerResponse {
        let route = Self.route(for: request.path)
        // Swift has no array destructuring patterns, so match on
        // (method, component count, first component, last component); the
        // middle component of three-part paths is the resource id.
        let first = route.first ?? ""
        let last = route.last ?? ""
        let id = route.count > 1 ? route[1] : ""

        switch (request.method, route.count, first, last) {
        // Handshake
        case (.get, 1, "version", _):
            return try await version()
        case (.get, 1, "_ping", _):
            return try await ping()
        case (.get, 1, "info", _):
            return try await info()

        // Containers
        case (.get, 2, "containers", "json"):
            let data = try await cli(["list", "--all", "--format", "json"]).stdout
            let all = Self.boolQuery(request, "all")
            return Self.ok(try AppleContainerJSON.containersListBody(fromAppleList: data, all: all))

        case (.get, 3, "containers", "json"):
            return Self.ok(try await inspectContainerBody(id: id))

        case (.post, 2, "containers", "create"):
            return try await createContainer(request)

        case (.post, 3, "containers", "start"):
            try await cli(["start", id])
            return Self.ok(status: 204)

        case (.post, 3, "containers", "stop"):
            try await cli(stopArguments(id: id, request: request))
            return Self.ok(status: 204)

        case (.post, 3, "containers", "restart"):
            // No `container restart`; a stop (tolerating "already stopped")
            // followed by start is the equivalent.
            _ = try? await cli(stopArguments(id: id, request: request))
            try await cli(["start", id])
            return Self.ok(status: 204)

        case (.post, 3, "containers", "kill"):
            var arguments = ["kill"]
            if let signal = Self.query(request, "signal") {
                arguments += ["--signal", signal]
            }
            arguments.append(id)
            try await cli(arguments)
            return Self.ok(status: 204)

        case (.delete, 2, "containers", _):
            var arguments = ["delete"]
            if Self.boolQuery(request, "force") { arguments.append("--force") }
            arguments.append(id)
            try await cli(arguments)
            return Self.ok(status: 204)

        case (.post, 2, "containers", "prune"):
            let output = try await cli(["prune"]).stdoutText
            return Self.ok(try AppleContainerJSON.pruneBody(
                fromCLIOutput: output, deletedKey: "ContainersDeleted"
            ))

        case (.post, 3, "containers", "wait"):
            return try await waitContainer(id: id)

        case (.post, 3, "containers", "top"), (.get, 3, "containers", "top"):
            return try await topContainer(id: id)

        case (.get, 3, "containers", "stats"):
            return Self.ok(try await statsOnce(id: id))

        // Exec
        case (.post, 3, "containers", "exec"):
            return try createExec(containerID: id, request: request)
        case (.post, 3, "exec", "resize"):
            return resizeExec(id: id, request: request)
        case (.get, 3, "exec", "json"):
            return try inspectExec(id: id)

        // Unsupported container operations
        case (.post, 3, "containers", "pause"),
             (.post, 3, "containers", "unpause"):
            throw Self.unsupported("Pause/unpause")
        case (.post, 3, "containers", "rename"):
            throw Self.unsupported("Renaming containers")
        case (.post, 3, "containers", "update"):
            throw Self.unsupported("Restart policies")
        case (.post, 1, "commit", _):
            throw Self.unsupported("Committing containers to images")
        case (_, 3, "containers", "archive"):
            throw Self.unsupported("Direct file transfer")

        // Images
        case (.get, 2, "images", "json"):
            let data = try await cli(["image", "list", "--format", "json"]).stdout
            lastImagesList = data
            return Self.ok(try AppleContainerJSON.imagesListBody(fromAppleList: data))

        case (.delete, 2, "images", _):
            var arguments = ["image", "delete"]
            if Self.boolQuery(request, "force") { arguments.append("--force") }
            arguments.append(try await imageReference(forID: id))
            try await cli(arguments)
            // Docker answers 200 with a delete report; the client only checks
            // the status, so an empty array suffices.
            return Self.ok(try AppleContainerJSON.encode([[String: String]]()))

        case (.post, 3, "images", "tag"):
            guard let repo = Self.query(request, "repo") else {
                throw DockerError.apiError(status: 400, message: "missing repo")
            }
            let tag = Self.query(request, "tag") ?? "latest"
            let source = try await imageReference(forID: id)
            try await cli(["image", "tag", source, "\(repo):\(tag)"])
            return Self.ok(status: 201)

        case (.post, 2, "images", "prune"):
            // Docker's filter `dangling=false` means "prune all unused".
            let filters = Self.query(request, "filters") ?? ""
            let danglingOnly = filters.contains("\"dangling\":[\"true\"]")
            var arguments = ["image", "prune"]
            if !danglingOnly { arguments.append("--all") }
            let output = try await cli(arguments).stdoutText
            return Self.ok(try AppleContainerJSON.pruneBody(
                fromCLIOutput: output, deletedKey: "ImagesDeleted"
            ))

        case (.get, 3, "images", "history"):
            throw Self.unsupported("Image layer history")

        // Volumes
        case (.get, 1, "volumes", _):
            let data = try await cli(["volume", "list", "--format", "json"]).stdout
            return Self.ok(try AppleContainerJSON.volumesListBody(fromAppleList: data))

        case (.post, 2, "volumes", "create"):
            return try await createVolume(request)

        case (.delete, 2, "volumes", _):
            try await cli(["volume", "delete", id])
            return Self.ok(status: 204)

        case (.post, 2, "volumes", "prune"):
            let output = try await cli(["volume", "prune"]).stdoutText
            return Self.ok(try AppleContainerJSON.pruneBody(
                fromCLIOutput: output, deletedKey: "VolumesDeleted"
            ))

        // Networks
        case (.get, 1, "networks", _):
            let data = try await cli(["network", "list", "--format", "json"]).stdout
            return Self.ok(try AppleContainerJSON.networksListBody(fromAppleList: data))

        case (.post, 2, "networks", "create"):
            return try await createNetwork(request)

        case (.post, 2, "networks", "prune"):
            let output = try await cli(["network", "prune"]).stdoutText
            return Self.ok(try AppleContainerJSON.pruneBody(
                fromCLIOutput: output, deletedKey: "NetworksDeleted"
            ))

        case (.get, 2, "networks", _):
            return try await inspectNetwork(id: id)

        case (.delete, 2, "networks", _):
            try await cli(["network", "delete", id])
            return Self.ok(status: 204)

        case (.post, 3, "networks", "connect"),
             (.post, 3, "networks", "disconnect"):
            throw Self.unsupported("Attaching running containers to networks")

        // System
        case (.get, 2, "system", "df"):
            let data = try await cli(["system", "df", "--format", "json"]).stdout
            return Self.ok(try AppleContainerJSON.dfBody(fromAppleDF: data))

        case (.post, 2, "build", "prune"):
            throw Self.unsupported("Build cache pruning")

        default:
            throw DockerError.apiError(
                status: 501,
                message: "\(request.method.rawValue) \(request.path): \(Self.unsupportedMessage)"
            )
        }
    }

    // MARK: - Handshake endpoints

    private func systemStatusJSON() async throws -> [String: Any] {
        let result = try await cli(["system", "status", "--format", "json"])
        return AppleContainerJSON.object(try AppleContainerJSON.decode(result.stdout))
    }

    private static func isRunning(_ status: [String: Any]) -> Bool {
        AppleContainerJSON.string(status["status"]).lowercased() == "running"
    }

    /// `GET /version` backs `negotiate()` — the connect handshake. When the
    /// apple/container services are down, start them once and re-check, so
    /// connecting a host brings the engine up the way the local Docker socket
    /// implies a running daemon.
    private func version() async throws -> DockerResponse {
        var status = (try? await systemStatusJSON()) ?? [:]
        if !Self.isRunning(status) {
            // `system start` may exit non-zero on its interactive kernel
            // prompt (stdin is closed) while still registering the API
            // server, so its failure is not authoritative — re-check status.
            _ = try? await runner.run(["system", "start"])
            status = try await systemStatusJSON()
        }
        guard Self.isRunning(status) else {
            throw DockerError.connectionFailed(
                "apple/container services are not running (try `container system start`)"
            )
        }
        let versionText = AppleContainerJSON.string(status["apiServerVersion"])
        return Self.ok(try AppleContainerJSON.versionBody(appServerVersion: versionText))
    }

    private func ping() async throws -> DockerResponse {
        let status = try await systemStatusJSON()
        guard AppleContainerJSON.string(status["status"]).lowercased() == "running" else {
            throw DockerError.connectionFailed("apple/container services are not running")
        }
        return Self.ok(Data("OK".utf8))
    }

    private func info() async throws -> DockerResponse {
        let containersData = try await cli(["list", "--all", "--format", "json"]).stdout
        let imagesData = try await cli(["image", "list", "--format", "json"]).stdout
        let status = try await systemStatusJSON()

        let containers = AppleContainerJSON.array(try AppleContainerJSON.decode(containersData))
        let images = AppleContainerJSON.array(try AppleContainerJSON.decode(imagesData))
        let running = containers.filter {
            AppleContainerJSON.string($0["status"]).lowercased() == "running"
        }.count

        let body = try AppleContainerJSON.infoBody(
            containersTotal: containers.count,
            containersRunning: running,
            imagesCount: images.count,
            serverVersion: AppleContainerJSON.string(status["apiServerVersion"]),
            ncpu: Self.hostCPUCount(),
            memTotal: Self.hostMemoryBytes(),
            hostName: ProcessInfo.processInfo.hostName
        )
        return Self.ok(body)
    }

    // MARK: - Containers

    private func stopArguments(id: String, request: DockerRequest) -> [String] {
        var arguments = ["stop"]
        if let timeout = Self.query(request, "t") {
            arguments += ["--time", timeout]
        }
        arguments.append(id)
        return arguments
    }

    /// Fetches one container's CLI inspect object, or throws 404.
    private func appleInspect(id: String) async throws -> [String: Any] {
        let data = try await cli(["inspect", id]).stdout
        guard let element = AppleContainerJSON.array(try AppleContainerJSON.decode(data)).first else {
            throw DockerError.apiError(status: 404, message: "No such container: \(id)")
        }
        return element
    }

    private func inspectContainerBody(id: String) async throws -> Data {
        try AppleContainerJSON.containerInspectBody(fromAppleInspect: try await appleInspect(id: id))
    }

    /// Translates the Docker create body into `container create` arguments.
    private func createContainer(_ request: DockerRequest) async throws -> DockerResponse {
        guard let body = request.body,
              let json = try? AppleContainerJSON.decode(body) as? [String: Any] else {
            throw DockerError.apiError(status: 400, message: "invalid create request body")
        }

        var arguments = ["create"]
        if let name = Self.query(request, "name") {
            arguments += ["--name", name]
        }
        for env in (json["Env"] as? [String]) ?? [] {
            arguments += ["--env", env]
        }
        for (key, value) in (json["Labels"] as? [String: String]) ?? [:] {
            arguments += ["--label", "\(key)=\(value)"]
        }
        if (json["Tty"] as? Bool) == true {
            arguments.append("--tty")
        }
        if let workingDir = json["WorkingDir"] as? String, !workingDir.isEmpty {
            arguments += ["--workdir", workingDir]
        }

        let hostConfig = AppleContainerJSON.object(json["HostConfig"])
        for bind in (hostConfig["Binds"] as? [String]) ?? [] {
            arguments += ["--volume", bind]
        }
        if let bindings = hostConfig["PortBindings"] as? [String: Any] {
            for (containerPort, value) in bindings.sorted(by: { $0.key < $1.key }) {
                // "80/tcp" → port + protocol; each {HostIp, HostPort} entry
                // becomes one --publish spec.
                let parts = containerPort.split(separator: "/")
                let port = parts.first.map(String.init) ?? containerPort
                let proto = parts.count > 1 ? String(parts[1]) : "tcp"
                for binding in AppleContainerJSON.array(value) {
                    let hostPort = AppleContainerJSON.string(binding["HostPort"])
                    let hostIP = AppleContainerJSON.string(binding["HostIp"])
                    guard !hostPort.isEmpty else { continue }
                    let prefix = hostIP.isEmpty ? "" : "\(hostIP):"
                    arguments += ["--publish", "\(prefix)\(hostPort):\(port)/\(proto)"]
                }
            }
        }
        if AppleContainerJSON.object(hostConfig["RestartPolicy"]).isEmpty == false {
            let policy = AppleContainerJSON.string(
                AppleContainerJSON.object(hostConfig["RestartPolicy"])["Name"]
            )
            if !policy.isEmpty, policy != "no" {
                throw Self.unsupported("Restart policies")
            }
        }
        if (hostConfig["AutoRemove"] as? Bool) == true {
            arguments.append("--rm")
        }
        if let memory = hostConfig["Memory"] as? Int64, memory > 0 {
            arguments += ["--memory", "\(max(memory / 1_048_576, 1))M"]
        }
        if let nanoCPUs = hostConfig["NanoCpus"] as? Int64, nanoCPUs > 0 {
            arguments += ["--cpus", String(max(Int(nanoCPUs / 1_000_000_000), 1))]
        }

        let networking = AppleContainerJSON.object(json["NetworkingConfig"])
        for network in AppleContainerJSON.object(networking["EndpointsConfig"]).keys.sorted() {
            arguments += ["--network", network]
        }

        // Entrypoint: the CLI takes a single override command; extra
        // entrypoint elements lead the argument list.
        var trailing: [String] = []
        let entrypoint = (json["Entrypoint"] as? [String]) ?? []
        if let first = entrypoint.first {
            arguments += ["--entrypoint", first]
            trailing += entrypoint.dropFirst()
        }
        trailing += (json["Cmd"] as? [String]) ?? []

        guard let image = json["Image"] as? String, !image.isEmpty else {
            throw DockerError.apiError(status: 400, message: "missing image")
        }
        arguments.append(image)
        arguments += trailing

        let output = try await cli(arguments).stdoutText
        // The CLI prints the new container's ID on the last non-empty line
        // (progress lines may precede it when the image needs fetching).
        let id = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? Self.query(request, "name") ?? ""
        let responseBody = try AppleContainerJSON.encode(["Id": id, "Warnings": []])
        return Self.ok(responseBody, status: 201)
    }

    private func waitContainer(id: String) async throws -> DockerResponse {
        // No CLI equivalent; poll until the container leaves "running".
        while true {
            let element = try await appleInspect(id: id)
            let status = AppleContainerJSON.string(element["status"]).lowercased()
            if status != "running" {
                return Self.ok(try AppleContainerJSON.encode(["StatusCode": 0]))
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Emulates `docker top` by running `ps aux` (falling back to plain `ps`)
    /// inside the container.
    private func topContainer(id: String) async throws -> DockerResponse {
        let result = try await runner.run(["exec", id, "/bin/sh", "-c", "ps aux 2>/dev/null || ps"])
        guard result.exitCode == 0, !result.stdout.isEmpty else {
            throw Self.unsupported("Process listing needs a shell with ps in the container")
        }
        return Self.ok(try AppleContainerJSON.topBody(fromPSOutput: result.stdoutText))
    }

    // MARK: - Stats

    private func statsOnce(id: String) async throws -> Data {
        let data = try await cli(["stats", "--no-stream", "--format", "json"]).stdout
        guard let entry = try AppleContainerJSON.statsEntry(forID: id, inAppleStats: data) else {
            throw DockerError.apiError(status: 404, message: "No stats for container: \(id)")
        }
        return try synthesizeStats(entry: entry, id: id)
    }

    private func synthesizeStats(entry: [String: Any], id: String) throws -> Data {
        let cpus = Self.hostCPUCount()
        let now = DispatchTime.now().uptimeNanoseconds
        let body = try AppleContainerJSON.statsBody(
            fromAppleStats: entry,
            onlineCPUs: cpus,
            monotonicNanoseconds: now,
            previous: statsBaselines[id]
        )
        statsBaselines[id] = (
            cpuTotal: AppleContainerJSON.int64(entry["cpuUsageUsec"]) * 1_000,
            system: Int64(clamping: now).multipliedReportingOverflow(by: Int64(cpus)).partialValue
        )
        return body
    }

    // MARK: - Exec

    private func createExec(containerID: String, request: DockerRequest) throws -> DockerResponse {
        guard let body = request.body,
              let json = try? AppleContainerJSON.decode(body) as? [String: Any],
              let command = json["Cmd"] as? [String], !command.isEmpty else {
            throw DockerError.apiError(status: 400, message: "invalid exec request body")
        }
        let id = UUID().uuidString
        execs[id] = ExecState(
            containerID: containerID,
            command: command,
            tty: (json["Tty"] as? Bool) ?? false
        )
        return Self.ok(try AppleContainerJSON.encode(["Id": id]))
    }

    private func resizeExec(id: String, request: DockerRequest) -> DockerResponse {
        if let process = execs[id]?.process,
           let w = Self.query(request, "w").flatMap(Int.init),
           let h = Self.query(request, "h").flatMap(Int.init) {
            process.resize(columns: w, rows: h)
        }
        return Self.ok()
    }

    private func inspectExec(id: String) throws -> DockerResponse {
        guard let state = execs[id] else {
            throw DockerError.apiError(status: 404, message: "No such exec instance: \(id)")
        }
        var body: [String: Any] = ["Running": state.running]
        if let exitCode = state.exitCode { body["ExitCode"] = exitCode }
        return Self.ok(try AppleContainerJSON.encode(body))
    }

    private func markExecFinished(id: String, exitCode: Int) {
        execs[id]?.running = false
        execs[id]?.exitCode = exitCode
        execs[id]?.process = nil
    }

    public func hijack(_ request: DockerRequest) async throws -> DockerHijackedConnection {
        let route = Self.route(for: request.path)
        guard request.method == .post, route.count == 3,
              route[0] == "exec", route[2] == "start",
              var state = execs[route[1]] else {
            throw DockerError.apiError(status: 404, message: "Unsupported hijack: \(request.path)")
        }
        let execID = route[1]

        var arguments = ["exec", "--interactive"]
        if state.tty { arguments.append("--tty") }
        arguments.append(state.containerID)
        arguments += state.command

        let process = try runner.interactive(arguments, tty: state.tty)
        state.process = process
        state.running = true
        execs[execID] = state

        // Bridge the process into the hijacked-connection shape. Non-TTY
        // output is framed into Docker's stdcopy format because that is what
        // the exec consumers demultiplex; TTY output passes through raw.
        let tty = state.tty
        let (bytes, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pump = Task { [weak self] in
            for await chunk in process.output {
                switch chunk {
                case .stdout(let data):
                    continuation.yield(tty ? data : Self.frame(data, stream: 1))
                case .stderr(let data):
                    continuation.yield(tty ? data : Self.frame(data, stream: 2))
                }
            }
            let exitCode = await process.waitForExit()
            await self?.markExecFinished(id: execID, exitCode: exitCode)
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }

        return DockerHijackedConnection(
            status: 101,
            headers: [:],
            bytes: bytes,
            write: { data in try await process.write(data) },
            close: { await process.close() }
        )
    }

    /// Wraps a payload into one Docker stdcopy frame:
    /// `[streamType, 0, 0, 0, UInt32 big-endian length]` + payload.
    static func frame(_ payload: Data, stream: UInt8) -> Data {
        var data = Data(capacity: payload.count + 8)
        data.append(stream)
        data.append(contentsOf: [0, 0, 0])
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }

    // MARK: - Streaming endpoints

    public func stream(_ request: DockerRequest) async throws -> DockerByteStream {
        let route = Self.route(for: request.path)
        let first = route.first ?? ""
        let last = route.last ?? ""
        let id = route.count > 1 ? route[1] : ""

        switch (request.method, route.count, first, last) {
        case (.get, 1, "events", _):
            // No event stream; HostSession falls back to polling on this.
            throw Self.unsupported("Event streaming")

        case (.get, 3, "containers", "logs"):
            return try await logsStream(id: id, request: request)

        case (.get, 3, "containers", "stats"):
            return statsStream(id: id)

        case (.get, 3, "containers", "export"):
            return DockerByteStream(
                status: 200,
                headers: [:],
                bytes: runner.stream(["export", id, "--output", "-"])
            )

        case (.post, 2, "images", "create"):
            return try pullStream(request)

        default:
            throw DockerError.apiError(
                status: 501,
                message: "\(request.method.rawValue) \(request.path) (stream): \(Self.unsupportedMessage)"
            )
        }
    }

    /// `container logs` bridged to Docker's log wire format. The consumer
    /// picks its parser from the container's TTY flag, so non-TTY output is
    /// framed and TTY output passes through raw — same contract as Docker.
    private func logsStream(id: String, request: DockerRequest) async throws -> DockerByteStream {
        let element = try await appleInspect(id: id)
        let initProcess = AppleContainerJSON.object(
            AppleContainerJSON.object(element["configuration"])["initProcess"]
        )
        let tty = (initProcess["terminal"] as? Bool) ?? false

        var arguments = ["logs"]
        if let tail = Self.query(request, "tail"), tail != "all", Int(tail) != nil {
            arguments += ["-n", tail]
        }
        if Self.boolQuery(request, "follow") {
            arguments.append("--follow")
        }
        arguments.append(id)

        let raw = runner.stream(arguments)
        if tty {
            return DockerByteStream(status: 200, headers: [:], bytes: raw)
        }

        let (framed, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pump = Task {
            do {
                for try await chunk in raw {
                    continuation.yield(Self.frame(chunk, stream: 1))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return DockerByteStream(status: 200, headers: [:], bytes: framed)
    }

    /// Streamed stats: polls the CLI and emits one synthesized Docker stats
    /// JSON line every interval, with `precpu_stats` from the prior sample so
    /// the decoder's CPU% math works.
    private func statsStream(id: String) -> DockerByteStream {
        let (bytes, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pump = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self else { break }
                    var line = try await self.statsOnce(id: id)
                    line.append(UInt8(ascii: "\n"))
                    continuation.yield(line)
                    try await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return DockerByteStream(status: 200, headers: [:], bytes: bytes)
    }

    /// `container image pull` progress translated into Docker's JSON-lines
    /// pull stream.
    private func pullStream(_ request: DockerRequest) throws -> DockerByteStream {
        guard let fromImage = Self.query(request, "fromImage") else {
            throw DockerError.apiError(status: 400, message: "missing fromImage")
        }
        let reference: String
        if let tag = Self.query(request, "tag"), !tag.isEmpty {
            reference = "\(fromImage):\(tag)"
        } else {
            reference = fromImage
        }

        let raw = runner.stream(["image", "pull", reference, "--progress", "plain"])
        let (bytes, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pump = Task {
            var buffer = Data()
            func emit(_ lineData: Data) {
                let line = String(decoding: lineData, as: UTF8.self)
                guard let json = AppleContainerJSON.pullProgressJSON(fromCLILine: line),
                      let encoded = try? AppleContainerJSON.encode(json) else { return }
                var out = encoded
                out.append(UInt8(ascii: "\n"))
                continuation.yield(out)
            }
            do {
                for try await chunk in raw {
                    buffer.append(chunk)
                    // The CLI redraws progress with \r and ends lines with \n;
                    // both delimit a progress line.
                    while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        emit(Data(buffer[buffer.startIndex ..< index]))
                        buffer.removeSubrange(buffer.startIndex ... index)
                    }
                }
                if !buffer.isEmpty { emit(buffer) }
                let done = try AppleContainerJSON.encode(["status": "Pull complete"])
                continuation.yield(done + Data([UInt8(ascii: "\n")]))
                continuation.finish()
            } catch {
                // Docker reports pull failures as an `error` JSON line.
                let message = (error as? DockerError)?.errorDescription ?? error.localizedDescription
                if let line = try? AppleContainerJSON.encode(["error": message]) {
                    continuation.yield(line + Data([UInt8(ascii: "\n")]))
                }
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return DockerByteStream(status: 200, headers: [:], bytes: bytes)
    }

    // MARK: - Images / volumes / networks helpers

    /// Resolves a `sha256:` image ID back to a CLI reference via the cached
    /// image list (refreshing it once on a miss).
    private func imageReference(forID id: String) async throws -> String {
        let resolved = AppleContainerJSON.imageReference(forID: id, inAppleList: lastImagesList)
        if resolved != id || !id.hasPrefix("sha256:") {
            return resolved
        }
        lastImagesList = try await cli(["image", "list", "--format", "json"]).stdout
        return AppleContainerJSON.imageReference(forID: id, inAppleList: lastImagesList)
    }

    private func createVolume(_ request: DockerRequest) async throws -> DockerResponse {
        guard let body = request.body,
              let json = try? AppleContainerJSON.decode(body) as? [String: Any],
              let name = json["Name"] as? String, !name.isEmpty else {
            throw DockerError.apiError(status: 400, message: "invalid volume create body")
        }
        var arguments = ["volume", "create"]
        for (key, value) in ((json["Labels"] as? [String: String]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["--label", "\(key)=\(value)"]
        }
        arguments.append(name)
        try await cli(arguments)

        // Docker answers with the created volume object.
        let inspected = try await cli(["volume", "inspect", name]).stdout
        let element = AppleContainerJSON.array(try AppleContainerJSON.decode(inspected)).first ?? ["name": name]
        let volume = AppleContainerJSON.volumeJSON(fromAppleVolume: element)
        return Self.ok(try AppleContainerJSON.encode(volume), status: 201)
    }

    private func createNetwork(_ request: DockerRequest) async throws -> DockerResponse {
        guard let body = request.body,
              let json = try? AppleContainerJSON.decode(body) as? [String: Any],
              let name = json["Name"] as? String, !name.isEmpty else {
            throw DockerError.apiError(status: 400, message: "invalid network create body")
        }
        var arguments = ["network", "create"]
        for (key, value) in ((json["Labels"] as? [String: String]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            arguments += ["--label", "\(key)=\(value)"]
        }
        arguments.append(name)
        try await cli(arguments)
        return Self.ok(try AppleContainerJSON.encode(["Id": name, "Warning": ""]), status: 201)
    }

    /// Raw network inspect: the CLI object is passed through (plus the fields
    /// `NetworkDetailView` reads), since this only feeds the raw Inspect tab
    /// and the attachments list (always empty here — apple/container does not
    /// report per-network container attachments).
    private func inspectNetwork(id: String) async throws -> DockerResponse {
        let data = try await cli(["network", "inspect", id]).stdout
        guard let element = AppleContainerJSON.array(try AppleContainerJSON.decode(data)).first else {
            throw DockerError.apiError(status: 404, message: "No such network: \(id)")
        }
        var body = element
        body["Name"] = id
        body["Containers"] = [String: Any]()
        return Self.ok(try AppleContainerJSON.encode(body))
    }
}
