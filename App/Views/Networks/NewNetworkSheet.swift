import SwiftUI
import AppCore
import DockerKit

/// Sheet to create a new network with a driver picker and optional labels.
struct NewNetworkSheet: View {
    let session: HostSession

    /// "overlay" needs swarm mode; offering it elsewhere only yields an error.
    private var drivers: [String] {
        session.info?.swarmActive == true ? ["bridge", "overlay", "macvlan"] : ["bridge", "macvlan"]
    }

    var body: some View {
        NewResourceSheet(
            title: String(localized: "New Network"),
            defaultDriver: "bridge",
            driverControl: { driver in
                Picker("Driver", selection: driver) {
                    ForEach(drivers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            },
            create: { name, driver, labels in
                await session.createNetwork(name: name, driver: driver, labels: labels) != nil
            }
        )
    }
}
