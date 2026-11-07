import Foundation
import DockerKit

/// A list that supports multi-select and bulk actions.
public enum BulkResource: String, Sendable, CaseIterable, Hashable {
    case containers
    case images
    case volumes
    case networks

    /// "3 containers", "1 image", ...
    public func countText(_ count: Int) -> String {
        switch self {
        case .containers: String(localized: "\(count) containers", bundle: .module)
        case .images: String(localized: "\(count) images", bundle: .module)
        case .volumes: String(localized: "\(count) volumes", bundle: .module)
        case .networks: String(localized: "\(count) networks", bundle: .module)
        }
    }

    /// The single-item remove kind of the shared confirmation.
    public var removeKind: DestructiveAction.Kind {
        switch self {
        case .containers: .removeContainer
        case .images: .removeImage
        case .volumes: .removeVolume
        case .networks: .removeNetwork
        }
    }
}

/// An action on several selected items.
public enum BulkAction: Hashable, Sendable {
    case start
    case stop
    case restart
    case pause
    case unpause
    case remove(force: Bool)
    /// Pull the image tag again (images only).
    case pull

    /// The actions of a list, without Remove (it has its own confirmation).
    /// Pause and Resume only show when the host engine supports them.
    public static func actions(for resource: BulkResource, capabilities: HostCapabilities) -> [BulkAction] {
        switch resource {
        case .containers:
            capabilities.pauseResume ? [.start, .stop, .restart, .pause, .unpause] : [.start, .stop, .restart]
        case .images:
            [.pull]
        case .volumes, .networks:
            []
        }
    }

    public var displayName: String {
        switch self {
        case .start: String(localized: "Start", bundle: .module)
        case .stop: String(localized: "Stop", bundle: .module)
        case .restart: String(localized: "Restart", bundle: .module)
        case .pause: String(localized: "Pause", bundle: .module)
        case .unpause: String(localized: "Resume", bundle: .module)
        case .remove: String(localized: "Remove", bundle: .module)
        case .pull: String(localized: "Pull Latest", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .pause: "pause.fill"
        case .unpause: "play"
        case .remove: "trash"
        case .pull: "arrow.down.circle"
        }
    }

    var isRemove: Bool {
        if case .remove = self { return true }
        return false
    }
}

/// One selected item: the id the engine uses and the name the user sees.
public struct BulkItem: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// An item that failed, with the engine's error text.
public struct BulkFailure: Hashable, Sendable {
    public let item: BulkItem
    public let message: String
}

/// The items an action can work on, and the ones it skips (a Start on a
/// container that already runs, a Pull on an untagged image).
public struct BulkPlan: Equatable, Sendable {
    public var eligible: [BulkItem]
    public var skipped: [BulkItem]

    /// Networks that the engine creates itself and that cannot be removed.
    public static let builtInNetworks: Set<String> = ["bridge", "host", "none"]

    public static func containers(_ containers: [ContainerSummary], action: BulkAction) -> BulkPlan {
        split(containers) { container in
            let item = BulkItem(id: container.id, name: container.displayName)
            let state = container.state
            let ok: Bool = switch action {
            case .start: !state.isRunning && state != .paused
            case .stop, .restart, .pause: state.isRunning
            case .unpause: state == .paused
            case .remove: true
            case .pull: false
            }
            return (item, ok)
        }
    }

    public static func images(_ images: [ImageSummary], action: BulkAction) -> BulkPlan {
        split(images) { image in
            switch action {
            case .remove:
                return (BulkItem(id: image.id, name: image.displayName), true)
            case .pull:
                // The pull reference is the tag; an untagged image has none.
                let tag = pullReference(image)
                return (BulkItem(id: tag ?? image.id, name: image.displayName), tag != nil)
            default:
                return (BulkItem(id: image.id, name: image.displayName), false)
            }
        }
    }

    public static func volumes(_ volumes: [Volume], action: BulkAction) -> BulkPlan {
        split(volumes) { (BulkItem(id: $0.name, name: $0.name), action.isRemove) }
    }

    public static func networks(_ networks: [NetworkResource], action: BulkAction) -> BulkPlan {
        split(networks) { network in
            (BulkItem(id: network.id, name: network.name), action.isRemove && !builtInNetworks.contains(network.name))
        }
    }

    /// The tag that Pull Latest pulls, or nil for an untagged image.
    public static func pullReference(_ image: ImageSummary) -> String? {
        image.repoTags.first { $0 != "<none>:<none>" && !$0.hasSuffix(":<none>") }
    }

    private static func split<T>(_ values: [T], _ classify: (T) -> (BulkItem, Bool)) -> BulkPlan {
        var plan = BulkPlan(eligible: [], skipped: [])
        for value in values {
            let (item, ok) = classify(value)
            if ok { plan.eligible.append(item) } else { plan.skipped.append(item) }
        }
        return plan
    }
}

/// What a bulk run did.
public struct BulkOutcome: Equatable, Sendable {
    public let action: BulkAction
    public let resource: BulkResource
    public var succeeded: [BulkItem] = []
    public var failed: [BulkFailure] = []
    /// Items the action did not apply to.
    public var skipped: [BulkItem] = []
    /// Items not run because the user cancelled.
    public var notRun: [BulkItem] = []

    public var total: Int { succeeded.count + failed.count + notRun.count }

    /// "3 done." or "3 done, 1 skipped."
    public var summary: String {
        skipped.isEmpty
            ? String(localized: "\(succeeded.count) done.", bundle: .module)
            : String(localized: "\(succeeded.count) done, \(skipped.count) skipped.", bundle: .module)
    }

    /// The banner text when items failed: a summary line, then one line per
    /// failed item. Nil when nothing failed.
    public var failureReport: String? {
        guard !failed.isEmpty else { return nil }
        let head = String(
            localized: "\(action.displayName): \(failed.count) of \(total) failed.", bundle: .module
        )
        return ([head] + failed.map { "\($0.item.name): \($0.message)" }).joined(separator: "\n")
    }
}

extension DestructiveAction {
    /// Removing several images at once. The impact counts the containers
    /// that use any of them.
    public static func removeImages(
        _ images: [ImageSummary], containers: [ContainerSummary], engine: Engine
    ) -> DestructiveAction {
        let ids = Set(images.map(\.id))
        let users = containers.filter { ids.contains($0.imageID) }.count
        return DestructiveAction(
            kind: .removeImage,
            targets: images.map(\.id),
            names: images.map(\.displayName),
            impact: users > 0 ? .containersUseImages(users) : .none,
            forceAvailable: supportsForce(.removeImage, engine: engine)
        )
    }

    /// Removing several volumes at once.
    public static func removeVolumes(
        names: [String], containers: [ContainerSummary], engine: Engine
    ) -> DestructiveAction {
        let set = Set(names)
        let users = containers.filter { $0.mounts.contains { set.contains($0.name ?? "") } }.count
        return DestructiveAction(
            kind: .removeVolume,
            targets: names,
            impact: users > 0 ? .containersUseVolumes(users) : .none,
            forceAvailable: supportsForce(.removeVolume, engine: engine)
        )
    }

    /// Removing several networks at once.
    public static func removeNetworks(_ networks: [NetworkResource]) -> DestructiveAction {
        DestructiveAction(kind: .removeNetwork, targets: networks.map(\.id), names: networks.map(\.name))
    }

    /// The names the dialog lists, at most `limit`, and how many it leaves out.
    public func listedNames(limit: Int = 10) -> (shown: [String], more: Int) {
        guard names.count > limit else { return (names, 0) }
        return (Array(names.prefix(limit - 1)), names.count - (limit - 1))
    }
}
