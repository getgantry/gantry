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
}
