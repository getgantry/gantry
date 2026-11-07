import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore

/// Applies a pasted or opened manifest with `kubectl apply -f -`.
struct KubeApplySheet: View {
    let browser: KubernetesBrowser
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var manifest = ""
    @State private var error: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply YAML").font(.title2.weight(.semibold))
            Text("Context: \(browser.selectedContext ?? "—"). Objects without a namespace go to \(targetNamespace).")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $manifest)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 320)
                .border(.separator)
                .accessibilityLabel(Text("Manifest"))
            if let error {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
            buttons
        }
        .padding(20)
    }

    private var targetNamespace: String {
        browser.namespace ?? browser.currentContext?.namespace ?? "default"
    }

    private var buttons: some View {
        HStack {
            Button("Open File…") { openFile() }
            Spacer()
            if running { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(running || manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .json]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        manifest = text
    }

    private func apply() {
        running = true
        error = nil
        Task {
            error = await browser.apply(manifest, operations: model.operations)
            running = false
            if error == nil { dismiss() }
        }
    }
}

/// Sets the replicas of a deployment or stateful set.
struct KubeScaleSheet: View {
    let resource: KubeResource
    let browser: KubernetesBrowser
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var replicas: Int

    init(resource: KubeResource, browser: KubernetesBrowser) {
        self.resource = resource
        self.browser = browser
        _replicas = State(initialValue: resource.replicas ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scale \(resource.reference)").font(.title3.weight(.semibold))
            Stepper(value: $replicas, in: 0...100) {
                Text("Replicas: \(replicas)")
            }
            if replicas == 0 {
                Text("All pods stop.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Scale") {
                    browser.scale(resource, to: replicas, operations: model.operations)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(replicas == resource.replicas)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Starts `kubectl port-forward` for a pod or a service.
struct KubePortForwardSheet: View {
    let resource: KubeResource
    let browser: KubernetesBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var remotePort: Int
    @State private var localPort: Int

    init(resource: KubeResource, browser: KubernetesBrowser) {
        self.resource = resource
        self.browser = browser
        let first = resource.ports.first?.port ?? 80
        _remotePort = State(initialValue: first)
        _localPort = State(initialValue: first < 1024 ? first + 8000 : first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Forward a Port of \(resource.reference)").font(.title3.weight(.semibold))
            Form {
                if !resource.ports.isEmpty {
                    Picker("Port", selection: $remotePort) {
                        ForEach(resource.ports, id: \.port) { port in
                            Text(verbatim: port.name.map { "\(port.port) (\($0))" } ?? String(port.port)).tag(port.port)
                        }
                    }
                } else {
                    TextField("Port", value: $remotePort, format: .number.grouping(.never))
                }
                TextField("Local Port", value: $localPort, format: .number.grouping(.never))
                Text("Use 0 to let kubectl pick a free port. Gantry listens on 127.0.0.1 only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(1...65535).contains(remotePort) || !(0...65535).contains(localPort))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func start() {
        guard let client = browser.client else { return }
        browser.portForwards.start(client, resource: resource, localPort: localPort, remotePort: remotePort)
        dismiss()
    }
}

/// The active port forwards, with Open and Stop.
struct KubePortForwardsPopover: View {
    let forwards: KubePortForwards

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Port Forwards").font(.headline)
            if forwards.forwards.isEmpty {
                Text("No active port forwards. Use Forward Port on a pod or a service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(forwards.forwards) { forward in
                    KubePortForwardRow(forward: forward) { forwards.stop(forward.id) }
                }
                Divider()
                Button("Stop All") { forwards.stopAll() }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct KubePortForwardRow: View {
    let forward: KubePortForward
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "127.0.0.1:\(forward.localPort == 0 ? "…" : String(forward.localPort)) → \(forward.target):\(forward.remotePort)")
                    .font(.callout)
                    .textSelection(.enabled)
                Text(verbatim: [forward.context, forward.namespace].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = forward.state {
                    Text(verbatim: message).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer()
            if let url = forward.url, forward.state == .active {
                Link(destination: url) { Label("Open in Browser", systemImage: "safari") }
                    .labelStyle(.iconOnly)
                    .help("Open \(url.absoluteString)")
            }
            Button(action: stop) {
                Label(isFailed ? "Remove" : "Stop", systemImage: isFailed ? "xmark.circle" : "stop.circle")
            }
            .labelStyle(.iconOnly)
            .help(isFailed ? "Remove from the list" : "Stop this port forward")
        }
    }

    private var isFailed: Bool {
        if case .failed = forward.state { true } else { false }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch forward.state {
        case .starting: ProgressView().controlSize(.mini).accessibilityLabel(Text("Starting"))
        case .active: KubeHealthIcon(health: .ok)
        case .failed: KubeHealthIcon(health: .failed)
        }
    }
}
