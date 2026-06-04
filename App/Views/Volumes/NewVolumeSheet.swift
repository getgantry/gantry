import SwiftUI
import AppCore
import DockerKit

/// Sheet to create a new volume with an optional driver and labels.
struct NewVolumeSheet: View {
    let session: HostSession

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var driver = "local"
    @State private var labels: [LabelPair] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Volume")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Driver", text: $driver)
                    .textFieldStyle(.roundedBorder)
                LabelEditor(pairs: $labels)
            }
            .disabled(working)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() {
        working = true
        let nameValue = name.trimmingCharacters(in: .whitespaces)
        let driverValue = driver.trimmingCharacters(in: .whitespaces)
        let labelDict = labels.asDictionary
        Task {
            let created = await session.createVolume(
                name: nameValue,
                driver: driverValue.isEmpty ? "local" : driverValue,
                labels: labelDict
            )
            working = false
            if created != nil { dismiss() }
        }
    }
}
