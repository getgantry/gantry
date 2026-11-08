import Foundation
import Observation

/// The state of the Kubernetes section: contexts, the selected namespace
/// and kind, and the listed resources. It talks to the API server directly
/// (see ``KubeAPIClient``) and keeps the list live with a watch (see
/// ``watch()``); when a watch is not possible it polls.
@MainActor
@Observable
public final class KubernetesBrowser {
    /// The pause between two list refreshes when a watch is not possible.
    public static let refreshInterval: Duration = .seconds(5)
    static let contextKey = "kubernetes.context"
    static let namespaceKey = "kubernetes.namespace"

    public private(set) var contexts: [KubeContext] = []
    public private(set) var namespaces: [String] = []
    public private(set) var resources: [KubeResource] = []
    public private(set) var isLoading = false
    /// True while a watch keeps the list live.
    public private(set) var isWatching = false
    /// True after the first context load.
    public private(set) var isPrepared = false
    /// The error of the last load. Old resources stay on screen.
    public private(set) var loadError: String?
    /// The error of the last user action, for the banner.
    public var actionError: String?
    public private(set) var lastRefresh: Date?
    /// The client of the selected context, or nil without one.
    public private(set) var client: KubeAPIClient?

    public var selectedContext: String? {
        didSet {
            guard selectedContext != oldValue else { return }
            defaults.set(selectedContext, forKey: Self.contextKey)
            resources = []
            namespaces = []
            loadError = nil
            makeClient()
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
    @ObservationIgnored private let kubeconfigPaths: () -> [String]
    @ObservationIgnored private let transport: ((KubeConnection) -> any KubeTransport)?
    @ObservationIgnored private var config = KubeConfigFile()
    /// The raw objects of the list by uid, for watch events.
    @ObservationIgnored private var items: [String: KubeResource] = [:]

    public init(
        defaults: UserDefaults = .standard,
        kubeconfigPaths: @escaping () -> [String] = { KubeConfig.paths() },
        transport: ((KubeConnection) -> any KubeTransport)? = nil
    ) {
        self.defaults = defaults
        self.kubeconfigPaths = kubeconfigPaths
        self.transport = transport
    }

    /// Changes when the list must load again; the view restarts ``watch()`` on it.
    public var selectionKey: String {
        "\(selectedContext ?? "")|\(namespace ?? "*")|\(kind.rawValue)"
    }

    public var currentContext: KubeContext? { contexts.first { $0.name == selectedContext } }

    /// The namespace for objects without one: the selected one, the one of
    /// the context, or `default`.
    public var targetNamespace: String {
        namespace ?? currentContext?.namespace ?? "default"
    }

    // MARK: - Loading

    /// Loads the contexts. Call it when the section opens.
    public func prepare() async {
        await loadContexts()
        isPrepared = true
    }

    public func loadContexts() async {
        let paths = kubeconfigPaths()
        do {
            config = try await Task.detached { try KubeConfigFile.load(paths: paths) }.value
            contexts = config.contextList(appleClusters: appleClusters)
            loadError = nil
        } catch {
            config = KubeConfigFile()
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
        } else {
            makeClient()
        }
    }

    /// Builds the client of the selected context. A broken context (a
    /// missing certificate file) shows its error in the list.
    private func makeClient() {
        guard let selectedContext else { client = nil; return }
        do {
            let connection = try config.connection(for: selectedContext)
            client = KubeAPIClient(connection: connection, transport: transport?(connection))
        } catch {
            client = nil
            loadError = Self.message(error)
        }
    }

    /// Loads the list, and the namespaces when they are not known yet.
    /// Returns the resourceVersion of the list for a watch.
    @discardableResult
    public func reload() async -> String? {
        guard let client else { return nil }
        let key = selectionKey
        let kind = kind
        let namespace = kind.isNamespaced ? namespace : nil
        isLoading = true
        defer { isLoading = false }
        if namespaces.isEmpty, let names = try? await client.namespaces(), key == selectionKey {
            namespaces = names
        }
        do {
            let data = try await client.send(KubeRequests.list(kind, namespace: namespace))
            let list = try KubeResourceParser.parse(data, kind: kind)
            guard key == selectionKey else { return nil }
            setItems(list)
            loadError = nil
            lastRefresh = Date()
            return KubeWatchEvent.listResourceVersion(data)
        } catch is CancellationError {
            return nil
        } catch {
            guard key == selectionKey, !Task.isCancelled else { return nil }
            loadError = Self.message(error)
            return nil
        }
    }

    /// Keeps the list live until the task is cancelled: a list, then a watch
    /// from its resourceVersion. A watch that ends starts again; a lost
    /// resourceVersion (410) or an error lists again. Without watch it polls.
    public func watch(interval: Duration = KubernetesBrowser.refreshInterval, retry: Duration = .seconds(2)) async {
        defer { isWatching = false }
        while !Task.isCancelled {
            guard var version = await reload(), let client else {
                isWatching = false
                try? await Task.sleep(for: interval)
                continue
            }
            let kind = kind
            let namespace = kind.isNamespaced ? namespace : nil
            let key = selectionKey
            watching: while !Task.isCancelled, key == selectionKey {
                isWatching = true
                do {
                    for try await line in client.lines(KubeRequests.watch(kind, namespace: namespace, resourceVersion: version)) {
                        guard key == selectionKey else { break watching }
                        switch KubeWatchEvent.parse(line, kind: kind) {
                        case .changed(let type, let resource, let newVersion):
                            apply(type, resource)
                            version = newVersion ?? version
                            lastRefresh = Date()
                        case .bookmark(let newVersion):
                            version = newVersion
                        case .expired:
                            break watching
                        case .ignored:
                            break
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    isWatching = false
                    if (error as? KubeAPIError)?.statusCode == 403 || (error as? KubeAPIError)?.statusCode == 405 {
                        // No watch permission: poll.
                        try? await Task.sleep(for: interval)
                    } else {
                        try? await Task.sleep(for: retry)
                    }
                    break watching
                }
            }
        }
    }

    private func setItems(_ list: [KubeResource]) {
        items = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        resources = list
    }

    private func apply(_ type: KubeWatchEvent.Change, _ resource: KubeResource) {
        switch type {
        case .added, .modified:
            if items[resource.id] != nil, let index = resources.firstIndex(where: { $0.id == resource.id }) {
                resources[index] = resource
                if kind == .events { resources = KubeWatchEvent.sorted(resources, kind: kind) }
            } else {
                resources.append(resource)
                resources = KubeWatchEvent.sorted(resources, kind: kind)
            }
            items[resource.id] = resource
        case .deleted:
            items[resource.id] = nil
            resources.removeAll { $0.id == resource.id }
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
            return try await Self.waitForRollout(client, resource, operation: operation)
        }
    }

    public func restart(_ resource: KubeResource, operations: OperationCenter) {
        perform(operations, title: String(localized: "Restart \(resource.reference)", bundle: .module)) { client, operation in
            try await client.restart(resource)
            return try await Self.waitForRollout(client, resource, operation: operation)
        }
    }

    private static func waitForRollout(_ client: KubeAPIClient, _ resource: KubeResource, operation: LongOperation) async throws -> String? {
        operation.update(progress: String(localized: "Waiting for the rollout…", bundle: .module))
        return try await client.rolloutStatus(resource) { message in
            Task { @MainActor in operation.update(progress: message) }
        }
    }

    /// Applies a manifest with server-side apply. Returns the result of each
    /// object; throws only when the YAML cannot be read or there is no context.
    public func apply(_ manifest: String, operations: OperationCenter) async throws -> [KubeApplyResult] {
        guard let client else { throw KubeAPIError.noContext }
        let target = targetNamespace
        let collector = KubeApplyCollector()
        let operation = operations.run(.kubernetes, title: String(localized: "Apply YAML", bundle: .module)) { _ in
            let results = try await client.apply(manifest, defaultNamespace: target)
            await collector.set(results)
            let failed = results.count { !$0.succeeded }
            if failed > 0 {
                throw KubeAPIError.status(code: 0, reason: nil, message: String(localized: "\(failed) of \(results.count) objects failed.", bundle: .module))
            }
            return String(localized: "\(results.count) objects applied.", bundle: .module)
        }
        await operation.wait()
        await reload()
        if let results = await collector.results { return results }
        if case .failed(let message) = operation.state { throw KubeAPIError.status(code: 0, reason: nil, message: message) }
        return []
    }

    private func perform(
        _ operations: OperationCenter,
        title: String,
        body: @escaping @MainActor (KubeAPIClient, LongOperation) async throws -> String?
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

/// Holds apply results across the operation closure.
actor KubeApplyCollector {
    var results: [KubeApplyResult]?
    func set(_ value: [KubeApplyResult]) { results = value }
}
