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
    /// Layers in the order first seen, their latest line, and the status
    /// line without a layer (e.g. "Pulling from library/nginx").
    @State private var tracker = PullProgressTracker()
    /// The pull in the operation center; it keeps running when the sheet
    /// closes with Continue in Background.
    @State private var operation: LongOperation?

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
                    InlineErrorText(message: message)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let operation { operation.cancelIn(session) }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if isBusy {
                    Button("Continue in Background") { dismiss() }
                        .help("The pull keeps running. Follow it in Activity.")
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
                            Text(tracker.statusLine.isEmpty ? String(localized: "Starting…") : tracker.statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if phase == .done {
                        Label("Pull complete", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }

                    ForEach(tracker.layerOrder, id: \.self) { layerID in
                        if let progress = tracker.layers[layerID] {
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

        tracker = PullProgressTracker()
        phase = .pulling

        let auth: RegistryAuth?
        if showAuth, !username.isEmpty {
            auth = RegistryAuth(username: username, password: password, serverAddress: server)
        } else {
            auth = nil
        }

        operation = ImagePullOperation.start(
            reference: ref,
            auth: auth,
            session: session,
            onProgress: { tracker = $0 },
            onFinish: { error in
                if let error {
                    phase = .failed(error.localizedDescription)
                } else {
                    phase = .done
                }
            }
        )
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
