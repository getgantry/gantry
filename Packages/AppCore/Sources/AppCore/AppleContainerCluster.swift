import Foundation

extension AppleContainerControl {
    // MARK: - Kubernetes clusters (apple/container 1.5+)

    /// The CNI that `cluster create` installs.
    public enum ClusterCNI: Sendable, Equatable, Hashable {
        /// The bundled kindnet manifest.
        case standard
        /// No CNI (`--cni NONE`, CLI 1.6.0+). Nodes stay NotReady until one is applied.
        case none
        /// A custom CNI manifest file (`--cni <path>`).
        case manifest(String)
    }

    /// The options of `container cluster create`. Nil and empty values leave
    /// the CLI default.
    public struct ClusterCreateOptions: Sendable, Equatable {
        public var name: String
        public var workers: Int?
        public var cpus: Int?
        /// Memory per node with an optional K/M/G/T/P suffix, for example `4G`.
        public var memory: String?
        public var nodeImage: String?
        public var cni: ClusterCNI
        /// Remove the node containers when they stop (`--rm`).
        public var removeOnStop: Bool
        public var scheme: String?
        public var maxConcurrentDownloads: Int?
        /// The kubeconfig the CLI merges the new context into, passed as
        /// `KUBECONFIG`. Nil keeps `~/.kube/config`.
        public var kubeconfigPath: String?

        public init(
            name: String,
            workers: Int? = nil,
            cpus: Int? = nil,
            memory: String? = nil,
            nodeImage: String? = nil,
            cni: ClusterCNI = .standard,
            removeOnStop: Bool = false,
            scheme: String? = nil,
            maxConcurrentDownloads: Int? = nil,
            kubeconfigPath: String? = nil
        ) {
            self.name = name
            self.workers = workers
            self.cpus = cpus
            self.memory = memory
            self.nodeImage = nodeImage
            self.cni = cni
            self.removeOnStop = removeOnStop
            self.scheme = scheme
            self.maxConcurrentDownloads = maxConcurrentDownloads
            self.kubeconfigPath = kubeconfigPath
        }

        /// The argv after the `container` binary. `command` is `cluster` or,
        /// on CLI 1.5.0 to 1.6.0, `k8s`.
        public func arguments(command: String = "cluster") -> [String] {
            var args = [command, "create", "--name", name]
            if removeOnStop { args.append("--rm") }
            if let cpus, cpus > 0 { args += ["--cpus", String(cpus)] }
            if let memory = trimmed(memory) { args += ["--memory", memory] }
            if let scheme = trimmed(scheme) { args += ["--scheme", scheme] }
            if let maxConcurrentDownloads, maxConcurrentDownloads > 0 {
                args += ["--max-concurrent-downloads", String(maxConcurrentDownloads)]
            }
            if let nodeImage = trimmed(nodeImage) { args += ["--node-image", nodeImage] }
            switch cni {
            case .standard: break
            case .none: args += ["--cni", "NONE"]
            case .manifest(let path):
                if let path = trimmed(path) { args += ["--cni", path] }
            }
            if let workers, workers > 0 { args += ["--workers", String(workers)] }
            return args
        }

        private func trimmed(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
    }

    /// The cluster subcommand of the installed CLI, or an error when the CLI
    /// is older than 1.5.0.
    public static func clusterCommand() async throws -> String {
        guard let command = await ContainerTooling.currentFeatures().clusterCommand else {
            throw AppleControlError.command(
                "Kubernetes clusters need apple container CLI \(ContainerTooling.clustersVersion) or later."
            )
        }
        return command
    }

    /// `container cluster list`, parsed from its table.
    public static func listClusters(
        command: String? = nil,
        cliOverride: String? = nil
    ) async throws -> [ContainerCluster] {
        let resolved = try await resolveClusterCommand(command)
        let output = try await runCluster([resolved, "list"], cliOverride: cliOverride)
        return ContainerCluster.parseList(output)
    }

    /// `container cluster create`. Pulls the node image and boots every node,
    /// which takes minutes. Each output line goes to `output`; cancelling the
    /// task stops the CLI.
    public static func createCluster(
        _ options: ClusterCreateOptions,
        command: String? = nil,
        cliOverride: String? = nil,
        output: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let resolved = try await resolveClusterCommand(command)
        try await runClusterStreaming(
            options.arguments(command: resolved),
            environment: kubeconfigEnvironment(options.kubeconfigPath),
            cliOverride: cliOverride,
            output: output
        )
    }

    /// `container cluster delete --name <name>`. Also removes the cluster
    /// context from the kubeconfig at `kubeconfigPath` (default `~/.kube/config`).
    public static func deleteCluster(
        _ name: String,
        kubeconfigPath: String? = nil,
        command: String? = nil,
        cliOverride: String? = nil
    ) async throws {
        let resolved = try await resolveClusterCommand(command)
        try await runCluster(
            [resolved, "delete", "--name", name],
            environment: kubeconfigEnvironment(kubeconfigPath),
            cliOverride: cliOverride
        )
    }

    /// `container cluster write-config --name <name> --kubeconfig <path>`. The
    /// CLI merges the context into the file, and creates it when it is missing.
    public static func writeClusterConfig(
        _ name: String,
        kubeconfigPath: String,
        command: String? = nil,
        cliOverride: String? = nil
    ) async throws {
        let resolved = try await resolveClusterCommand(command)
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try await runCluster(writeConfigArguments(name, kubeconfigPath: kubeconfigPath, command: resolved), cliOverride: cliOverride)
    }

    public static func writeConfigArguments(_ name: String, kubeconfigPath: String, command: String = "cluster") -> [String] {
        [command, "write-config", "--name", name, "--kubeconfig", kubeconfigPath]
    }

    /// `container cluster load-image --name <cluster> <image>`: copies a local
    /// image into the containerd of every node (or only `nodes`).
    public static func loadImageIntoCluster(
        _ image: String,
        cluster: String,
        platform: String? = nil,
        nodes: [String] = [],
        command: String? = nil,
        cliOverride: String? = nil
    ) async throws {
        let resolved = try await resolveClusterCommand(command)
        let args = loadImageArguments(image, cluster: cluster, platform: platform, nodes: nodes, command: resolved)
        try await runCluster(args, cliOverride: cliOverride)
    }

    public static func loadImageArguments(
        _ image: String,
        cluster: String,
        platform: String? = nil,
        nodes: [String] = [],
        command: String = "cluster"
    ) -> [String] {
        var args = [command, "load-image", "--name", cluster, image]
        if let platform, !platform.isEmpty { args += ["--platform", platform] }
        for node in nodes where !node.isEmpty { args += ["--node", node] }
        return args
    }

    /// `container inspect <node>…`: the raw JSON of the node containers.
    public static func rawInspectClusterNodes(_ nodes: [String], cliOverride: String? = nil) async throws -> String {
        guard !nodes.isEmpty else { return "" }
        return try await runCluster(["inspect"] + nodes, cliOverride: cliOverride)
    }

    /// `kubectl config use-context <context>`, for the clipboard.
    public static func kubectlUseContextCommand(for cluster: String, kubeconfigPath: String? = nil) -> String {
        var command = "kubectl config use-context \(shellQuoted(cluster))"
        if let kubeconfigPath, !kubeconfigPath.isEmpty {
            command = "KUBECONFIG=\(shellQuoted(kubeconfigPath)) " + command
        }
        return command
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@=~+,"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains), !value.hasPrefix("~") { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Plumbing

    private static func resolveClusterCommand(_ command: String?) async throws -> String {
        if let command { return command }
        return try await clusterCommand()
    }

    private static func kubeconfigEnvironment(_ path: String?) -> [String: String] {
        guard let path, !path.isEmpty else { return [:] }
        return ["KUBECONFIG": path]
    }

    @discardableResult
    private static func runCluster(
        _ arguments: [String],
        environment: [String: String] = [:],
        cliOverride: String?
    ) async throws -> String {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let result = await run(cli, arguments, environment: environment)
        guard result.exitCode == 0 else { throw commandError(arguments, stderr: result.stderr) }
        return result.stdout
    }

    private static func commandError(_ arguments: [String], stderr: String) -> AppleControlError {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        // The CLI logs progress to stderr; the error is the `Error:` line.
        let message = lines.last { $0.hasPrefix("Error:") }
            ?? lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? ""
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .command(text.isEmpty ? "container \(arguments.joined(separator: " ")) failed." : text)
    }

    /// Runs the CLI and delivers each stdout and stderr line to `output`.
    /// Both `\n` and `\r` end a line, because the progress line is redrawn
    /// with `\r` on a terminal.
    private static func runClusterStreaming(
        _ arguments: [String],
        environment: [String: String],
        cliOverride: String?,
        output: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let cli = cliPath(override: cliOverride) else { throw AppleControlError.cliNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let splitter = ClusterLineSplitter(output: output)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        splitter.append(data)
                    }
                }
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd() { splitter.append(rest) }
                    splitter.finish()
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else { throw commandError(arguments, stderr: splitter.transcript) }
    }
}

/// Splits streamed process output into lines and keeps a short transcript for
/// the error message.
private final class ClusterLineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var tail: [String] = []
    private let output: @Sendable (String) -> Void

    init(output: @escaping @Sendable (String) -> Void) {
        self.output = output
    }

    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return tail.joined(separator: "\n")
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...end)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        record(lines)
        lock.unlock()
        lines.forEach(output)
    }

    func finish() {
        lock.lock()
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        let lines = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [line]
        record(lines)
        lock.unlock()
        lines.forEach(output)
    }

    private func record(_ lines: [String]) {
        tail.append(contentsOf: lines)
        if tail.count > 50 { tail.removeFirst(tail.count - 50) }
    }
}
