import Foundation

/// App-wide notifications used to bridge global menu commands to the
/// currently visible content views without tight coupling.
extension Notification.Name {
    /// Posted by the Docker > Refresh All command. ContentView observes it and
    /// refreshes the selected session.
    static let gantryRefreshAll = Notification.Name("gantryRefreshAll")

    /// Posted by the Docker > New Container… command. ContainerListView observes
    /// it and opens its create sheet when containers are in view.
    static let gantryNewContainer = Notification.Name("gantryNewContainer")

    /// Posted when a Compose file is opened from Finder (Open With / Quick
    /// Action) or the File menu. ContentView observes it and presents the
    /// Compose Up sheet. The `object` is the file `URL`.
    static let gantryOpenComposeFile = Notification.Name("gantryOpenComposeFile")

    /// Posted to jump the sidebar to a host's Containers section (e.g. after a
    /// Compose project comes up). The `object` is the host `UUID`.
    static let gantrySelectHostContainers = Notification.Name("gantrySelectHostContainers")

    /// Posted to open a specific container's detail view (e.g. from the menu-bar
    /// panel). The `object` is a `ContainerJump` carrying the host and container.
    static let gantrySelectContainer = Notification.Name("gantrySelectContainer")

    /// Posted when a Dockerfile is dropped on the window, opened from Finder, or
    /// chosen from the Docker menu. ContentView observes it and presents the
    /// Build Image sheet. The `object` is the Dockerfile `URL`.
    static let gantryOpenDockerfile = Notification.Name("gantryOpenDockerfile")

    /// Posted to open the apple/container install/upgrade sheet on demand (e.g.
    /// from the Add Host form when the CLI is missing).
    static let gantryShowContainerSetup = Notification.Name("gantryShowContainerSetup")

    /// Open a container's Terminal tab in debug-shell mode. Object: the
    /// container id (`String`). Posted alongside `gantrySelectContainer`, which
    /// does the navigating — this only chooses what the pane shows on arrival.
    static let gantryOpenDebugShell = Notification.Name("gantryOpenDebugShell")

}

/// Identifies a container to jump to, carried by `.gantrySelectContainer`.
struct ContainerJump: Hashable {
    let hostID: UUID
    let containerID: String
}
