import SwiftUI
import AppCore

/// Creates a new `container machine` from an image. Creation pulls the image
/// and boots the machine, so it streams a spinner until the CLI returns.
struct CreateMachineSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var image = "alpine:3.22"
    @State private var name = ""
    @State private var creating = false
    @State private var error: String?

    private var canCreate: Bool {
        !creating
            && !image.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Machine")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                field("Name") {
                    TextField("my-machine", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(creating)
                }
                field("Image") {
                    TextField("alpine:3.22", text: $image)
                        .textFieldStyle(.roundedBorder)
                        .disabled(creating)
                }
            }

            Text("Creating pulls the image and boots a long-lived Linux environment.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                if creating {
                    ProgressView().controlSize(.small)
                    Text("Creating \(name)…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(creating)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }

    private func create() {
        let machineName = name.trimmingCharacters(in: .whitespaces)
        let machineImage = image.trimmingCharacters(in: .whitespaces)
        creating = true
        error = nil
        Task {
            let ok = await session.createMachine(image: machineImage, name: machineName)
            creating = false
            if ok {
                dismiss()
            } else {
                error = session.lastError ?? "Could not create the machine."
                session.lastError = nil
            }
        }
    }
}
