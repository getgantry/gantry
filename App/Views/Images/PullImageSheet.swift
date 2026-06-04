import SwiftUI
import AppCore
import DockerKit

/// Sheet to pull an image by reference with optional registry credentials and a
/// live per-layer progress list.
struct PullImageSheet: View {
    let session: HostSession

    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var showAuth = false
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""

    /// Tracks the lifecycle of the pull operation.
    private enum Phase: Equatable {
        case idle
        case pulling
        case done
        case failed(String)
    }

    @State private var phase: Phase = .idle
    /// Ordered layer ids as first seen, so the progress list stays stable.
    @State private var layerOrder: [String] = []
    /// Latest progress per layer id.
    @State private var layers: [String: PullProgress] = [:]
    /// Non-layer status lines (e.g. "Pulling from library/nginx").
    @State private var statusLine = ""
    @State private var pullTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pull Image")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Reference (e.g. nginx:latest)", text: $reference)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                    .onSubmit(startPull)

                DisclosureGroup("Registry Authentication", isExpanded: $showAuth) {
                    VStack(spacing: 8) {
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                        TextField("Server (optional)", text: $server)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 4)
                    .disabled(isBusy)
                }
                .font(.callout)
            }

            Divider()

            progressArea
                .frame(minHeight: 140, maxHeight: 260)

            HStack {
                if case .failed(let message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    pullTask?.cancel()
                    dismiss()
                }
                if phase == .done {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Pull") { startPull() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { pullTask?.cancel() }
    }

    private var isBusy: Bool { phase == .pulling }

    @ViewBuilder
    private var progressArea: some View {
        switch phase {
        case .idle:
            ContentUnavailableView(
                "Ready to Pull",
                systemImage: "arrow.down.circle",
                description: Text("Enter an image reference and choose Pull.")
            )
        case .pulling, .done, .failed:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if phase == .pulling {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(statusLine.isEmpty ? "Starting…" : statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if phase == .done {
                        Label("Pull complete", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }

                    ForEach(layerOrder, id: \.self) { layerID in
                        if let progress = layers[layerID] {
                            LayerProgressRow(layerID: layerID, progress: progress)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func startPull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !isBusy else { return }

        layerOrder = []
        layers = [:]
        statusLine = ""
        phase = .pulling

        let auth: RegistryAuth?
        if showAuth, !username.isEmpty {
            auth = RegistryAuth(username: username, password: password, serverAddress: server)
        } else {
            auth = nil
        }

        pullTask = Task {
            do {
                let stream = try await session.pullImage(reference: ref, auth: auth)
                for try await update in stream {
                    apply(update)
                }
                phase = .done
                await session.refreshImages()
            } catch is CancellationError {
                // Sheet is closing; nothing to surface.
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Folds one progress line into the per-layer state.
    private func apply(_ update: PullProgress) {
        if let id = update.id, !id.isEmpty {
            if layers[id] == nil { layerOrder.append(id) }
            layers[id] = update
        } else if !update.status.isEmpty {
            statusLine = update.status
        }
    }
}

/// One layer's progress row: id, status, and a determinate bar when byte counts
/// are known (indeterminate otherwise).
private struct LayerProgressRow: View {
    let layerID: String
    let progress: PullProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(layerID)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Text(progress.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let current = progress.current, let total = progress.total, total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .controlSize(.small)
            }
        }
    }
}
