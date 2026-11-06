import SwiftUI
import AppCore

/// The toolbar button for long operations: a live badge with the running
/// count that opens the activity list.
struct ActivityToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ActivityButton()
        }
    }
}

struct ActivityButton: View {
    @Environment(AppModel.self) private var model
    @State private var showList = false

    var body: some View {
        let center = model.operations
        Button {
            showList.toggle()
        } label: {
            Label(String(localized: "Activity"), systemImage: iconName(center))
        }
        .badge(center.runningCount)
        .help(String(localized: "Long operations: pulls, builds, deploys and installs"))
        .accessibilityValue(String(localized: "\(center.runningCount) running"))
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            ActivityList(center: center)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gantryShowActivity)) { _ in
            showList = true
        }
    }

    private func iconName(_ center: OperationCenter) -> String {
        center.runningCount > 0 ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle"
    }
}

extension Notification.Name {
    /// Opens the activity list (for example after a sheet started work).
    static let gantryShowActivity = Notification.Name("gantryShowActivity")
}

/// The list of running and finished operations.
struct ActivityList: View {
    let center: OperationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if center.operations.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Activity"),
                    systemImage: "checkmark.circle",
                    description: Text("Pulls, builds, deploys and installs show here while they run.")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(center.ordered) { operation in
                            ActivityRow(operation: operation, center: center)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Text("Activity").font(.headline)
            Spacer()
            Button(String(localized: "Clear Finished")) { center.clearFinished() }
                .buttonStyle(.borderless)
                .disabled(!center.operations.contains { $0.state.isFinished })
        }
        .padding(10)
    }
}

/// One operation: title, host, progress, Cancel and its log tail.
struct ActivityRow: View {
    let operation: LongOperation
    let center: OperationCenter
    @State private var showLog = false
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            progress
            if case .failed(let message) = operation.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !operation.log.isEmpty {
                DisclosureGroup(String(localized: "Output"), isExpanded: $showLog) {
                    logView
                }
                .font(.caption)
            }
        }
        .padding(10)
        .confirmationDialog(
            String(localized: "Cancel \(operation.title)?"),
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Stop"), role: .destructive) { center.cancel(operation) }
            Button(String(localized: "Keep Running"), role: .cancel) {}
        } message: {
            Text(operation.cancelConfirmation ?? "")
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ActivityStateIcon(state: operation.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title).font(.callout.weight(.medium)).lineLimit(2)
                if let host = operation.hostName {
                    Text(host).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            trailingButton
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if operation.canCancel {
            Button(String(localized: "Cancel")) {
                if operation.cancelConfirmation != nil { confirmCancel = true } else { center.cancel(operation) }
            }
            .controlSize(.small)
        } else if operation.isCancelling {
            Text("Stopping…").font(.caption).foregroundStyle(.secondary)
        } else if operation.state.isFinished {
            Button {
                center.dismiss(operation)
            } label: {
                Label(String(localized: "Dismiss"), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss"))
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch operation.state {
        case .running:
            if let fraction = operation.fraction {
                ProgressView(value: fraction) { progressLabel }
            } else {
                ProgressView { progressLabel }.progressViewStyle(.linear)
            }
        case .succeeded(let summary?):
            Text(summary).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var progressLabel: some View {
        Text(operation.progressText ?? String(localized: "Working…"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var logView: some View {
        ScrollView {
            Text(operation.logTail(40).joined(separator: "\n"))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }
}

private struct ActivityStateIcon: View {
    let state: OperationState

    var body: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel(String(localized: "Done"))
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                .accessibilityLabel(String(localized: "Failed"))
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Cancelled"))
        }
    }
}

/// Starts a long operation in the activity list of the session's app.
@MainActor
enum LongOperationRunner {
    @discardableResult
    static func run(
        _ kind: OperationKind,
        title: String,
        session: HostSession?,
        center: OperationCenter? = nil,
        cancelConfirmation: String? = nil,
        body: @escaping @MainActor (LongOperation) async throws -> String?
    ) -> LongOperation {
        // AppModel gives every session the app's center; the fallback only
        // keeps the work running if that link is missing.
        let target = center ?? session?.operations ?? OperationCenter()
        return target.run(
            kind, title: title, host: session?.host.name, cancelConfirmation: cancelConfirmation, body: body
        )
    }
}

extension LongOperation {
    /// Cancels this operation through the center of `session`.
    @MainActor
    func cancelIn(_ session: HostSession) {
        session.operations?.cancel(self)
    }
}
