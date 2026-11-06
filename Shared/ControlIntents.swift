import AppIntents
import GantryShared
#if GANTRY_WIDGET_EXTENSION
import AppKit
#endif

// This file is in the app and in the widget extension. In the app, the
// intents do the work. In the sandboxed extension, they hand it to the app
// through a `gantry://control` URL (see `ControlRequest`).

/// A container that a control can start or stop, from the fleet snapshot.
struct ControlContainerEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Favorite Container")
    }

    static let defaultQuery = ControlContainerQuery()

    /// "hostID|name" (see `FleetSnapshot.ContainerRef.id`).
    var id: String
    var name: String
    var hostName: String

    init(_ ref: FleetSnapshot.ContainerRef) {
        id = ref.id
        name = ref.name
        hostName = ref.hostName
    }

    init(id: String, name: String, hostName: String) {
        self.id = id
        self.name = name
        self.hostName = hostName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(hostName)")
    }
}

struct ControlContainerQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ControlContainerEntity] {
        let known = SnapshotStore.standard().read()?.containers ?? []
        return identifiers.compactMap { id in
            if let ref = known.first(where: { $0.id == id }) { return ControlContainerEntity(ref) }
            // A container that is gone now keeps its name in the control.
            guard let parts = FleetSnapshot.ContainerRef.split(id) else { return nil }
            return ControlContainerEntity(id: id, name: parts.name, hostName: "")
        }
    }

    func suggestedEntities() async throws -> [ControlContainerEntity] {
        (SnapshotStore.standard().read()?.containers ?? []).map(ControlContainerEntity.init)
    }
}

/// The configuration of the favorite-container control.
struct FavoriteContainerConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Favorite Container"
    static let isDiscoverable = false

    @Parameter(title: "Container")
    var container: ControlContainerEntity?
}

struct SetAppleServicesIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start or Stop apple/container Services"
    static let isDiscoverable = false

    @Parameter(title: "Running")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try await ControlDispatch.send(.setAppleServices(running: value))
        return .result()
    }
}

struct SetContainerRunningIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start or Stop Container"
    static let isDiscoverable = false

    @Parameter(title: "Container")
    var container: ControlContainerEntity?

    @Parameter(title: "Running")
    var value: Bool

    init() {}

    init(container: ControlContainerEntity?) {
        self.container = container
    }

    func perform() async throws -> some IntentResult {
        guard let container, let parts = FleetSnapshot.ContainerRef.split(container.id) else {
            throw ControlDispatchError.noContainer
        }
        try await ControlDispatch.send(.setContainer(hostID: parts.hostID, name: parts.name, running: value))
        return .result()
    }
}

#if compiler(>=6.4)
// macOS 27 can run a control's intent in the app itself.
@available(macOS 27.0, *)
extension SetAppleServicesIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

@available(macOS 27.0, *)
extension SetContainerRunningIntent {
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}
#endif

enum ControlDispatchError: Error, CustomLocalizedStringResourceConvertible {
    case noContainer
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noContainer: "Choose a container for this control."
        case .appNotReady: "Open Gantry once, then try again."
        }
    }
}

enum ControlDispatch {
    static func send(_ action: ControlAction) async throws {
        #if GANTRY_WIDGET_EXTENSION
        guard let snapshot = SnapshotStore.standard().read(), !snapshot.controlToken.isEmpty else {
            throw ControlDispatchError.appNotReady
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let url = ControlRequest(action: action, token: snapshot.controlToken).url
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        #else
        try await ControlExecutor.run(action)
        #endif
    }
}
