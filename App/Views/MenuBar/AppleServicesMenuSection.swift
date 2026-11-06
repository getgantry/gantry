import SwiftUI
import AppCore

/// Menu-bar strip showing the apple/container background services and letting
/// the user start/stop them without dropping to a terminal — the services must
/// be running for any apple host to work, so this is the natural place to nudge
/// them up.
struct AppleServicesMenuSection: View {
    /// Optional `container` CLI path override from a configured apple host.
    let cliOverride: String?

    @State private var status: AppleServiceStatus = .unknown
    @State private var busy = false
    @State private var errorText: String?
    /// A stop waiting for the inline confirmation (a dialog would close
    /// the menu bar panel).
    @State private var pendingStop: DestructiveAction?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("apple/container")
                    .font(.subheadline.weight(.semibold))
                StatusSymbol(systemName: dotSymbol, tint: dotColor, size: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                control
            }
            if let pendingStop {
                stopConfirmation(pendingStop)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task { await refresh() }
    }

    @ViewBuilder
    private var control: some View {
        if busy {
            ProgressView().controlSize(.mini)
        } else {
            switch status {
            case .running:
                Button("Stop…") {
                    pendingStop = .services(.stopServices, runningContainers: model.appleRunningContainerCount)
                }
                .controlSize(.small)
                .disabled(pendingStop != nil)
            case .stopped:
                Button("Start") { act { try await AppleContainerControl.startServices(cliOverride: cliOverride) } }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .unavailable:
                EmptyView()
            case .unknown:
                Button("Refresh") { Task { await refresh() } }
                    .controlSize(.small)
            }
        }
    }

    private var dotColor: Color {
        switch status {
        case .running: .green
        case .stopped: .orange
        case .unavailable: .gray
        case .unknown: .secondary
        }
    }

    private var statusText: String {
        switch status {
        case .running: String(localized: "running")
        case .stopped: String(localized: "stopped")
        case .unavailable: String(localized: "not installed")
        case .unknown: String(localized: "checking…")
        }
    }

    private var dotSymbol: String {
        switch status {
        case .running: "circle.fill"
        case .stopped: "stop.circle"
        case .unavailable: "minus.circle"
        case .unknown: "circle.dotted"
        }
    }

    private func stopConfirmation(_ action: DestructiveAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(DestructiveActionText.title(action)).font(.caption.weight(.semibold))
            Text(DestructiveActionText.message(action))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { pendingStop = nil }
                Button(DestructiveActionText.confirmLabel(action), role: .destructive) {
                    pendingStop = nil
                    act { try await AppleContainerControl.stopServices(cliOverride: cliOverride) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
    }

    private func refresh() async {
        status = await AppleContainerControl.serviceStatus(cliOverride: cliOverride)
    }

    private func act(_ operation: @escaping () async throws -> Void) {
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await operation()
            } catch {
                errorText = error.localizedDescription
            }
            await refresh()
        }
    }
}
