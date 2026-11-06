import Foundation
import AppCore

/// The one path that removes a host, used by the sidebar and by Settings so
/// both show the same confirmation and ask for the same Touch ID / password
/// when it is on.
@MainActor
enum HostRemoval {
    /// The confirmation for removing `session`'s host.
    static func action(for session: HostSession) -> DestructiveAction {
        DestructiveAction(kind: .removeHost, targets: [session.host.id.uuidString], names: [session.host.name])
    }

    /// Disconnects and removes the host of a confirmed `action` and returns
    /// its id. ``DestructiveConfirmation`` has already asked for Touch ID.
    @discardableResult
    static func remove(_ action: DestructiveAction, from model: AppModel) async -> UUID? {
        guard let raw = action.targets.first, let hostID = UUID(uuidString: raw) else { return nil }
        if let session = model.session(id: hostID) {
            await session.disconnect()
        }
        model.removeHost(id: hostID)
        return hostID
    }
}
