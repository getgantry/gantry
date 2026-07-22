import SwiftUI
import AppKit
import AppCore

/// Creates a new `container machine` from an image. Creation pulls the image
/// and boots the machine, so it streams a spinner until the CLI returns.
struct CreateMachineSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var image = "alpine:3.22"
    @State private var name = ""
    @State private var cpus = defaultCPUs
    @State private var memoryGB = defaultMemoryGB
    @State private var nestedVirtualization = false
    @State private var kernelPath = ""
    @State private var creating = false
    @State private var error: String?
    /// nil until the CLI version is known; gates the 1.1-only boot options.
    @State private var features: ContainerTooling.Features?

    private static let bytesPerGB: Double = 1_073_741_824
    /// A sensible starting CPU count: half the host's cores, at least one.
    private static var defaultCPUs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount / 2) }
    /// The CLI default is half of system memory — mirror that here.
    private static var defaultMemoryGB: Int {
        max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB / 2).rounded()))
    }
    private var maxCPU: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemGB: Int { max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / Self.bytesPerGB).rounded())) }

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
                field("CPUs") {
                    Stepper(value: $cpus, in: 1...maxCPU) {
                        Text("\(cpus)").monospacedDigit()
                    }
                    .disabled(creating)
                }
                field("Memory") {
                    Stepper(value: $memoryGB, in: 1...maxMemGB) {
                        Text("\(memoryGB) GB").monospacedDigit()
                    }
                    .disabled(creating)
                }
                if features?.nestedVirtualization ?? false {
                    bootOptions
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
        .task { features = await ContainerTooling.currentFeatures() }
    }

    /// apple/container 1.1 boot options: nested virtualization and a custom
    /// kernel. Nesting needs a kernel built with `CONFIG_KVM=y`, so the two are
    /// presented together and the toggle is off unless the Mac supports it.
    @ViewBuilder
    private var bootOptions: some View {
        let unsupported = MachineCapabilities.nestedVirtualizationUnavailableReason

        field("Nested") {
            Toggle("Nested virtualization", isOn: $nestedVirtualization)
                .toggleStyle(.checkbox)
                .disabled(creating || unsupported != nil)
        }
        field("Kernel") {
            TextField("System default", text: $kernelPath)
                .textFieldStyle(.roundedBorder)
                .disabled(creating)
            Button {
                pickKernel()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .disabled(creating)
        }
        Text(unsupported
             ?? "Nested virtualization runs VMs inside the machine. It needs a custom kernel built with CONFIG_KVM=y.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickKernel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a kernel binary (e.g. vmlinux)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        kernelPath = url.path
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
            let ok = await session.createMachine(
                image: machineImage,
                name: machineName,
                cpus: cpus,
                memory: "\(memoryGB)G",
                nestedVirtualization: nestedVirtualization,
                kernelPath: kernelPath.trimmingCharacters(in: .whitespaces)
            )
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
