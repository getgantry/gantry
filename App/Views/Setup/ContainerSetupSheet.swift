import SwiftUI
import AppCore

/// Prompts the user to install or upgrade the `apple/container` CLI when it is
/// missing or older than the version Gantry supports. Shown at launch and after
/// Gantry updates; the install runs through Homebrew with a live log.
struct ContainerSetupSheet: View {
    let status: ContainerTooling.Status
    /// Called when the user finishes (installed, or chose to skip).
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var done = false
    @State private var failure: String?
    @State private var log: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 520, height: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 26)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text("apple/container powers Gantry's local Linux containers")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var title: String {
        switch status.state {
        case .notInstalled: "Install apple/container"
        case .outdated: "Update apple/container"
        case .ok: "apple/container"
        }
    }

    @ViewBuilder
    private var content: some View {
        if running || done || failure != nil {
            logView
        } else {
            explainer
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch status.state {
            case .notInstalled:
                Text("Gantry can manage Linux containers natively on your Mac with Apple's `container` runtime — but it isn't installed yet.")
            case .outdated(let current):
                Text("Your `container` CLI is **\(current)**. Gantry is tested with **\(ContainerTooling.recommendedVersion)** and needs at least **\(ContainerTooling.minimumVersion)**.")
            case .ok:
                Text("apple/container is ready.")
            }

            // Recommend the official signed installer — it's the only build
            // that ships the machine API server, so `container machine` works.
            VStack(alignment: .leading, spacing: 8) {
                Label("Recommended: the official signed installer", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                Text("It's the only build with the **Machines** backend (`container machine`). Download the `.pkg`, then run it.")
                    .font(.callout).foregroundStyle(.secondary)
                Link(destination: ContainerTooling.installerPageURL) {
                    Label("Download Installer…", systemImage: "arrow.down.circle")
                }
                .font(.callout)
            }

            Divider().padding(.vertical, 2)

            if status.brewAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Or install via Homebrew (no `container machine` support):",
                          systemImage: "terminal")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Gantry will run `brew \(brewVerb) \(ContainerTooling.formula)` for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Homebrew (without `container machine`) is also available: install [Homebrew](https://brew.sh), then run `brew \(brewVerb) \(ContainerTooling.formula)`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line)
                    }
                    if let failure {
                        Label(failure, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).font(.callout).padding(.top, 6)
                    }
                    if done {
                        Label("apple/container is installed and ready.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout).padding(.top, 6)
                    }
                }
                .padding(16)
            }
            .onChange(of: log.count) {
                if let last = log.last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    private var footer: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            Button(done ? "Done" : "Later") { finish() }
                .keyboardShortcut(.cancelAction)
            if status.brewAvailable && !done {
                Button(status.state.isOutdated ? "Update" : "Install") {
                    Task { await runBrew() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(running)
            }
        }
        .padding(16)
    }

    private var brewVerb: String { status.state.isOutdated ? "upgrade" : "install" }

    private func runBrew() async {
        running = true
        failure = nil
        log.removeAll()
        do {
            let sink: @Sendable (String) -> Void = { line in
                Task { @MainActor in log.append(line) }
            }
            if status.state.isOutdated {
                try await ContainerTooling.upgrade(progress: sink)
            } else {
                try await ContainerTooling.install(progress: sink)
            }
            done = true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        running = false
    }

    private func finish() {
        onClose()
        dismiss()
    }
}

private extension ContainerTooling.State {
    var isOutdated: Bool {
        if case .outdated = self { return true }
        return false
    }
}
