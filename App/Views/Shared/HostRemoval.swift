import Foundation
import AppCore

/// The one path that removes a host, used by the sidebar and by Settings so
/// both ask for the same Touch ID / password confirmation when it is on.
@MainActor
enum HostRemoval {
    /// Confirms through ``BiometricGate``, then disconnects and removes the
    /// host. Returns false when the user did not confirm.
    static func remove(_ hostID: UUID, from model: AppModel) async -> Bool {
        let name = model.session(id: hostID)?.host.name ?? "host"
        guard await BiometricGate.confirm("remove host \(name)") else { return false }
        if let session = model.session(id: hostID) {
            await session.disconnect()
        }
        model.removeHost(id: hostID)
        return true
    }
}
