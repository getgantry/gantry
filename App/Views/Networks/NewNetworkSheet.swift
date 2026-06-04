import SwiftUI
import AppCore
import DockerKit

/// Sheet to create a new network with a driver picker and optional labels.
struct NewNetworkSheet: View {
    let session: HostSession

    @Environment(\.dismiss) private var dismiss

    private static let drivers = ["bridge", "overlay", "macvlan"]

    @State private var name = ""
    @State private var driver = "bridge"
    @State private var labels: [LabelPair] = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Network")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Picker("Driver", selection: $driver) {
                    ForEach(Self.drivers, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
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
        let labelDict = labels.asDictionary
        Task {
            let id = await session.createNetwork(name: nameValue, driver: driver, labels: labelDict)
            working = false
            if id != nil { dismiss() }
        }
    }
}
