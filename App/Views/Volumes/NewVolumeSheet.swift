import SwiftUI
import AppCore
import DockerKit

/// Sheet to create a new volume with an optional driver and labels.
struct NewVolumeSheet: View {
    let session: HostSession

    var body: some View {
        NewResourceSheet(
            title: "New Volume",
            defaultDriver: "local",
            driverControl: { driver in
                TextField("Driver", text: driver)
                    .textFieldStyle(.roundedBorder)
            },
            create: { name, driver, labels in
                let driverValue = driver.trimmingCharacters(in: .whitespaces)
                return await session.createVolume(
                    name: name,
                    driver: driverValue.isEmpty ? "local" : driverValue,
                    labels: labels
                ) != nil
            }
        )
    }
}
