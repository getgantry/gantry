import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// Starts `container cluster create`. Creation pulls the kindest/node image
/// and boots each node, so it runs in the background: the sheet closes at once
/// and the cluster list shows the progress.
struct CreateClusterSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = "dev"
    @State private var workers = 0
    @State private var cpus = 2
    @State private var memoryGB = 4
    @State private var nodeImage = ""
    @State private var cni: CNIChoice = .standard
    @State private var manifestPath = ""
    @State private var error: String?

    enum CNIChoice: Hashable {
        case standard, none, manifest
    }

    private static let bytesPerGB: Double = 1_073_741_824
    private var maxCPU: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    private var maxMemGB: Int { max(1, Int((Double(ProcessInfo.processInfo.physicalMemory) / Self.bytesPerGB).rounded())) }
    private var supportsWorkers: Bool { session.clusterFeatures?.clusterWorkers ?? false }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Container names: a letter or digit first, then letters, digits, `-`, `_` or `.`.
    private var nameIsValid: Bool {
        trimmedName.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]*/) != nil
    }

    private var nameInUse: Bool {
        session.clusters.contains { $0.name == trimmedName }
            || session.clusterCreations.contains { $0.id == trimmedName && $0.isRunning }
    }

    private var canCreate: Bool {
        nameIsValid && !nameInUse
            && (cni != .manifest || !manifestPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Cluster")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                field("Name") {
                    TextField("dev", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                if supportsWorkers {
                    field("Workers") {
                        Stepper(value: $workers, in: 0...8) {
                            Text("\(workers)").monospacedDigit()
                        }
                    }
                }
                field("CPUs") {
                    Stepper(value: $cpus, in: 1...maxCPU) {
                        Text("\(cpus) per node").monospacedDigit()
                    }
                }
                field("Memory") {
                    Stepper(value: $memoryGB, in: 1...maxMemGB) {
                        Text("\(memoryGB) GB per node").monospacedDigit()
                    }
                }
                field("Node image") {
                    TextField("CLI default (kindest/node)", text: $nodeImage)
                        .textFieldStyle(.roundedBorder)
                }
                field("CNI") {
                    Picker("CNI", selection: $cni) {
                        Text("Default (kindnet)").tag(CNIChoice.standard)
                        if supportsWorkers {
                            Text("None").tag(CNIChoice.none)
                        }
                        Text("Custom manifest…").tag(CNIChoice.manifest)
                    }
                    .labelsHidden()
                }
                if cni == .manifest {
                    HStack(alignment: .firstTextBaseline) {
                        Color.clear.frame(width: 80, height: 1)
                        TextField("Path to a CNI manifest", text: $manifestPath)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            pickManifest()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Choose a CNI manifest")
                        .accessibilityLabel("Choose a CNI manifest")
                    }
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if nameInUse {
                Label("A cluster with this name already exists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !trimmedName.isEmpty && !nameIsValid {
                Label("Use letters, digits, hyphens, dots and underscores.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await session.loadClusterSupport() }
    }

    private var footnote: String {
        var text = String(localized: "Creating pulls the node image and can take several minutes. The progress shows in the cluster list. The cluster context is added to ~/.kube/config.")
        if cni == .none {
            text += " " + String(localized: "Without a CNI, the nodes stay NotReady until you apply one.")
        }
        return text
    }

    private func field<V: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(minWidth: 80, alignment: .leading).fixedSize().foregroundStyle(.secondary)
            content()
        }
    }

    private func pickManifest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .json]
            .compactMap { $0 }
        panel.message = String(localized: "Choose a CNI manifest (YAML).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manifestPath = url.path
    }

    private func create() {
        let selectedCNI: AppleContainerControl.ClusterCNI = switch cni {
        case .standard: .standard
        case .none: .none
        case .manifest: .manifest(manifestPath.trimmingCharacters(in: .whitespaces))
        }
        let options = AppleContainerControl.ClusterCreateOptions(
            name: trimmedName,
            workers: supportsWorkers ? workers : nil,
            cpus: cpus,
            memory: "\(memoryGB)G",
            nodeImage: nodeImage,
            cni: selectedCNI
        )
        if session.startClusterCreation(options) {
            dismiss()
        } else {
            error = String(localized: "Could not start the cluster creation.")
        }
    }
}
