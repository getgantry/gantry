import Foundation
import DockerKit

public enum KubectlError: Error, LocalizedError, Equatable {
    case notInstalled
    case noContext
    case unexpectedOutput
    /// kubectl exited with an error; the text is its stderr.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "kubectl is not installed.", bundle: .module)
        case .noContext: String(localized: "Select a Kubernetes context.", bundle: .module)
        case .unexpectedOutput: String(localized: "kubectl returned output that Gantry cannot read.", bundle: .module)
        case .failed(let message): message
        }
    }

    /// Turns stderr into a message: drops the `error: ` prefix of kubectl.
    static func from(stderr: Data, exit: ChildProcessExit) -> KubectlError {
        var text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("error: ") { text = String(text.dropFirst(7)) }
        if text.hasPrefix("Error from server ") { text = String(text.dropFirst("Error from server ".count)) }
        return .failed(text.isEmpty ? String(localized: "kubectl failed (\(exit.summary)).", bundle: .module) : text)
    }
}

/// Runs `kubectl` for one context with the kubeconfig files of the browser.
/// The argument builders are pure, so tests check them without kubectl.
public struct KubectlClient: Sendable, Equatable {
    public var executable: String
    public var kubeconfigPaths: [String]
    public var context: String?

    /// Each read stops after this time, so a dead cluster does not hang the UI.
    public static let requestTimeout = "15s"

    public init(executable: String, kubeconfigPaths: [String], context: String?) {
        self.executable = executable
        self.kubeconfigPaths = kubeconfigPaths
        self.context = context
    }

    /// `KUBECONFIG` and a `PATH` with the kubectl and Homebrew directories:
    /// exec credential plugins (gcloud, aws) live there, and an app started
    /// from Finder has a short PATH.
    public var environment: [String: String] {
        var result: [String: String] = [:]
        if !kubeconfigPaths.isEmpty { result["KUBECONFIG"] = kubeconfigPaths.joined(separator: ":") }
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let directory = (executable as NSString).deletingLastPathComponent
        var path: [String] = []
        for entry in [directory, "/opt/homebrew/bin", "/usr/local/bin"] + current where !entry.isEmpty && !path.contains(entry) {
            path.append(entry)
        }
        result["PATH"] = path.joined(separator: ":")
        return result
    }

    /// `KUBECONFIG=…` entries for a terminal that does not merge the app environment.
    public var environmentEntries: [String] {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Argument builders

    func contextArguments() -> [String] {
        guard let context, !context.isEmpty else { return [] }
        return ["--context", context]
    }

    func namespaceArguments(_ namespace: String?) -> [String] {
        guard let namespace, !namespace.isEmpty else { return [] }
        return ["--namespace", namespace]
    }

    public func listArguments(_ kind: KubeResourceKind, namespace: String?) -> [String] {
        var args = contextArguments() + ["get", kind.kubectlName, "--output", "json", "--request-timeout", Self.requestTimeout]
        if kind.isNamespaced {
            let scoped = namespaceArguments(namespace)
            args += scoped.isEmpty ? ["--all-namespaces"] : scoped
        }
        return args
    }

    public func getArguments(_ resource: KubeResource, output: String) -> [String] {
        contextArguments() + namespaceArguments(resource.namespace)
            + ["get", resource.reference, "--output", output, "--request-timeout", Self.requestTimeout]
    }

    public func deleteArguments(_ resource: KubeResource) -> [String] {
        contextArguments() + namespaceArguments(resource.namespace) + ["delete", resource.reference, "--wait=false"]
    }

    public func scaleArguments(_ resource: KubeResource, replicas: Int) -> [String] {
        contextArguments() + namespaceArguments(resource.namespace)
            + ["scale", resource.reference, "--replicas", String(max(0, replicas))]
    }

    public func restartArguments(_ resource: KubeResource) -> [String] {
        contextArguments() + namespaceArguments(resource.namespace) + ["rollout", "restart", resource.reference]
    }

    public func rolloutStatusArguments(_ resource: KubeResource, timeout: String = "5m") -> [String] {
        contextArguments() + namespaceArguments(resource.namespace)
            + ["rollout", "status", resource.reference, "--timeout", timeout]
    }

    /// `kubectl apply -f -`; the manifest goes to stdin. A nil namespace
    /// keeps the namespace of the manifest or of the context.
    public func applyArguments(namespace: String?) -> [String] {
        contextArguments() + namespaceArguments(namespace) + ["apply", "--filename", "-"]
    }

    public func logsArguments(pod: KubeResource, container: String?, follow: Bool, tail: Int, previous: Bool = false) -> [String] {
        var args = contextArguments() + namespaceArguments(pod.namespace) + ["logs", pod.name]
        if let container, !container.isEmpty { args += ["--container", container] }
        if follow { args.append("--follow") }
        if previous { args.append("--previous") }
        args += ["--tail", String(tail), "--timestamps=false"]
        return args
    }

    /// An interactive shell: bash when the image has it, else sh.
    public func execArguments(pod: KubeResource, container: String?) -> [String] {
        var args = contextArguments() + namespaceArguments(pod.namespace) + ["exec", "--stdin", "--tty", pod.name]
        if let container, !container.isEmpty { args += ["--container", container] }
        args += ["--", "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"]
        return args
    }

    /// `kubectl port-forward` on 127.0.0.1. A local port of 0 lets kubectl choose.
    public func portForwardArguments(_ resource: KubeResource, localPort: Int, remotePort: Int) -> [String] {
        contextArguments() + namespaceArguments(resource.namespace)
            + ["port-forward", "--address", "127.0.0.1", resource.reference, "\(localPort == 0 ? "" : String(localPort)):\(remotePort)"]
    }

    // MARK: - Commands

    /// Runs kubectl to completion and returns stdout, or throws its stderr.
    public func run(_ arguments: [String], input: Data? = nil) async throws -> Data {
        let result = try await ChildProcess.run(executable, arguments, environment: environment, input: input)
        guard result.exit.succeeded else { throw KubectlError.from(stderr: result.stderr, exit: result.exit) }
        return result.stdout
    }

    /// The merged kubeconfig contexts. Works without a selected context.
    public func contexts(appleClusters: Set<String>) async throws -> [KubeContext] {
        let data = try await run(["config", "view", "--output", "json"])
        return try KubeConfig.parseContexts(data, appleClusters: appleClusters)
    }

    public func namespaces() async throws -> [String] {
        let data = try await run(contextArguments() + ["get", "namespaces", "--output", "json", "--request-timeout", Self.requestTimeout])
        return try KubeResourceParser.namespaces(data)
    }

    /// Lists `kind` in `namespace`; nil or empty lists every namespace.
    public func list(_ kind: KubeResourceKind, namespace: String?) async throws -> [KubeResource] {
        try KubeResourceParser.parse(try await run(listArguments(kind, namespace: namespace)), kind: kind)
    }

    /// The YAML of a resource. Secret values are hidden (see ``KubeSecretData``).
    public func yaml(for resource: KubeResource) async throws -> String {
        if resource.kind == .secrets {
            return try KubeSecretData.redactedYAML(fromJSON: try await run(getArguments(resource, output: "json")))
        }
        return String(decoding: try await run(getArguments(resource, output: "yaml")), as: UTF8.self)
    }

    public func json(for resource: KubeResource) async throws -> Data {
        try await run(getArguments(resource, output: "json"))
    }

    public func delete(_ resource: KubeResource) async throws {
        _ = try await run(deleteArguments(resource))
    }

    public func scale(_ resource: KubeResource, replicas: Int) async throws {
        _ = try await run(scaleArguments(resource, replicas: replicas))
    }

    public func restart(_ resource: KubeResource) async throws {
        _ = try await run(restartArguments(resource))
    }

    public func rolloutStatus(_ resource: KubeResource) async throws -> String {
        String(decoding: try await run(rolloutStatusArguments(resource)), as: UTF8.self)
    }

    /// Applies a manifest and returns the kubectl summary lines.
    public func apply(_ manifest: String, namespace: String?) async throws -> String {
        let data = try await run(applyArguments(namespace: namespace), input: Data(manifest.utf8))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
