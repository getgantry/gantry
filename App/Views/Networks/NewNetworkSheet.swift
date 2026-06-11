import SwiftUI
import AppCore
import DockerKit

/// Sheet to create a new network with a driver picker and optional labels.
struct NewNetworkSheet: View {
    let session: HostSession

    private static let drivers = ["bridge", "overlay", "macvlan"]

    var body: some View {
        NewResourceSheet(
            title: "New Network",
            defaultDriver: "bridge",
            driverControl: { driver in
                Picker("Driver", selection: driver) {
                    ForEach(Self.drivers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            },
            create: { name, driver, labels in
                await session.createNetwork(name: name, driver: driver, labels: labels) != nil
            }
        )
    }
}
