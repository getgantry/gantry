import Foundation
import Observation

/// The state of the Kubernetes section: kubectl, contexts, the selected
/// namespace and kind, and the listed resources. It refreshes on an
/// interval while the section is open (see ``watch()``).
@MainActor
@Observable
public final class KubernetesBrowser {
    public enum Availability: Equatable, Sendable {
        case unknown
        case missing
        case ready(String)
    }

    /// The pause between two list refreshes.
    public static let refreshInterval: Duration = .seconds(5)
    static let contextKey = "kubernetes.context"
    static let namespaceKey = "kubernetes.namespace"

    public private(set) var availability: Availability = .unknown
    public private(set) var contexts: [KubeContext] = []
    public private(set) var namespaces: [String] = []
    public private(set) var resources: [KubeResource] = []
    public private(set) var isLoading = false
    /// The error of the last load. Old resources stay on screen.
    public private(set) var loadError: String?
    /// The error of the last user action, for the banner.
    public var actionError: String?
    public private(set) var lastRefresh: Date?

    public var selectedContext: String? {
        didSet {
            guard selectedContext != oldValue else { return }
            defaults.set(selectedContext, forKey: Self.contextKey)
            resources = []
            namespaces = []
            loadError = nil
            namespace = contexts.first { $0.name == selectedContext }?.namespace
        }
    }

    /// nil lists every namespace.
    public var namespace: String? {
        didSet {
            guard namespace != oldValue else { return }
            defaults.set(namespace, forKey: Self.namespaceKey)
            resources = []
        }
    }

    public var kind: KubeResourceKind = .pods {
        didSet { if kind != oldValue { resources = []; loadError = nil } }
    }

    /// Names of apple/container clusters; their contexts come first.
    public var appleClusters: Set<String> = []

    public let portForwards = KubePortForwards()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let locate: () -> String?
    @ObservationIgnored private let kubeconfigPaths: () -> [String]

    public init(
        defaults: UserDefaults = .standard,
        locate: @escaping () -> String? = { KubectlTooling.cliPath() },
        kubeconfigPaths: @escaping () -> [String] = { KubeConfig.paths() }
    ) {
        self.defaults = defaults
        self.locate = locate
        self.kubeconfigPaths = kubeconfigPaths
    }

    /// Changes when the list must load again; the view restarts ``watch()`` on it.
    public var selectionKey: String {
        "\(selectedContext ?? "")|\(namespace ?? "*")|\(kind.rawValue)"
    }

    /// A client for the selected context, or nil without kubectl.
    public var client: KubectlClient? {
        guard case .ready(let path) = availability else { return nil }
        return KubectlClient(executable: path, kubeconfigPaths: kubeconfigPaths(), context: selectedContext)
    }

    public var currentContext: KubeContext? { contexts.first { $0.name == selectedContext } }

    // MARK: - Loading

    /// Finds kubectl and loads the contexts. Call it when the section opens.
    public func prepare() async {
        guard let path = locate() else {
            availability = .missing
            contexts = []
            return
        }
        availability = .ready(path)
        await loadContexts()
    }

    public func loadContexts() async {
        guard let client else { return }
        do {
            contexts = try await client.contexts(appleClusters: appleClusters)
            loadError = nil
        } catch {
            contexts = []
            loadError = Self.message(error)
        }
        let remembered = selectedContext ?? defaults.string(forKey: Self.contextKey)
        let preferred = KubeConfig.preferredContext(contexts, remembered: remembered)
        if preferred != selectedContext {
            selectedContext = preferred
            if preferred == remembered, let saved = defaults.string(forKey: Self.namespaceKey) {
                namespace = saved
            }
        }
    }

    /// Loads the list, and the namespaces when they are not known yet.
    public func reload() async {
        guard let client, client.context != nil else { return }
        let key = selectionKey
        let kind = kind
        let namespace = kind.isNamespaced ? namespace : nil
        isLoading = true
        defer { isLoading = false }
        if namespaces.isEmpty, let names = try? await client.namespaces(), key == selectionKey {
            namespaces = names
        }
        do {
            let items = try await client.list(kind, namespace: namespace)
            guard key == selectionKey else { return }
            resources = items
            loadError = nil
            lastRefresh = Date()
        } catch is CancellationError {
            return
        } catch {
            guard key == selectionKey, !Task.isCancelled else { return }
            loadError = Self.message(error)
        }
    }

    /// Reloads, then waits ``refreshInterval``, until the task is cancelled.
    public func watch(interval: Duration = KubernetesBrowser.refreshInterval) async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - Actions

    /// Deletes a resource. Errors go to the banner.
    public func delete(_ resource: KubeResource, operations: OperationCenter) {
        perform(operations, title: String(localized: "Delete \(resource.reference)", bundle: .module)) { client, _ in
            try await client.delete(resource)
            return nil
        }
    }

    public func scale(_ resource: KubeResource, to replicas: Int, operations: OperationCenter) {
        perform(operations, title: String(localized: "Scale \(resource.reference) to \(replicas)", bundle: .module)) { client, operation in
            try await client.scale(resource, replicas: replicas)
            operation.update(progress: String(localized: "Waiting for the rollout…", bundle: .module))
            return try await client.rolloutStatus(resource).split(separator: "\n").last.map(String.init)
        }
    }

    public func restart(_ resource: KubeResource, operations: OperationCenter) {
        perform(operations, title: String(localized: "Restart \(resource.reference)", bundle: .module)) { client, operation in
            try await client.restart(resource)
            operation.update(progress: String(localized: "Waiting for the rollout…", bundle: .module))
            return try await client.rolloutStatus(resource).split(separator: "\n").last.map(String.init)
        }
    }

    /// Applies a manifest. Returns nil on success, else the error for the sheet.
    public func apply(_ manifest: String, operations: OperationCenter) async -> String? {
        guard let client else { return KubectlError.notInstalled.errorDescription }
        let target = kind.isNamespaced ? namespace : nil
        let operation = operations.run(.kubernetes, title: String(localized: "Apply YAML", bundle: .module)) { _ in
            try await client.apply(manifest, namespace: target)
        }
        await operation.wait()
        if case .failed(let message) = operation.state { return message }
        await reload()
        return nil
    }

    private func perform(
        _ operations: OperationCenter,
        title: String,
        body: @escaping @MainActor (KubectlClient, LongOperation) async throws -> String?
    ) {
        guard let client else { return }
        actionError = nil
        let operation = operations.run(.kubernetes, title: title) { operation in
            try await body(client, operation)
        }
        Task { @MainActor [weak self] in
            await operation.wait()
            if case .failed(let message) = operation.state { self?.actionError = message }
            await self?.reload()
        }
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
