import SwiftUI
import AppIntents

/// The activity type that tells the system which container is on screen.
enum OnscreenActivity {
    static let containerType = "com.andrewkomkov.Gantry.viewContainer"
}

extension View {
    /// Marks the shown container as the on-screen entity, so Siri and Apple
    /// Intelligence can act on "this container" (macOS 15.2 and later).
    func onscreenContainer(hostID: UUID, containerID: String, name: String) -> some View {
        userActivity(OnscreenActivity.containerType) { activity in
            let id = ContainerEntity.makeID(hostID: hostID, containerID: containerID)
            activity.title = name
            activity.isEligibleForSearch = false
            activity.appEntityIdentifier = EntityIdentifier(for: ContainerEntity.self, identifier: id)
        }
    }
}
