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

    /// Posted to open the apple/container install/upgrade sheet on demand (e.g.
    /// from the Add Host form when the CLI is missing).
    static let gantryShowContainerSetup = Notification.Name("gantryShowContainerSetup")
}
