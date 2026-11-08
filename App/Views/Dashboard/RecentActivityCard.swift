import SwiftUI
import AppCore

/// The last long operations of every host (pulls, builds, deploys,
/// installs) on the dashboard, newest first. The full list stays in the
/// toolbar Activity popover.
struct RecentActivityCard: View {
    let operations: OperationCenter
    var limit = 6

    var body: some View {
        DashboardCard("Recent Activity", systemImage: "clock.arrow.circlepath") {
            Button("Show All") {
                NotificationCenter.default.post(name: .gantryShowActivity, object: nil)
            }
            .buttonStyle(.borderless)
            .disabled(operations.operations.isEmpty)
        } content: {
            let items = Array(operations.ordered.prefix(limit))
            if items.isEmpty {
                Text("Pulls, builds, deploys and installs show here while they run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, operation in
                        if index > 0 { Divider() }
                        RecentActivityRow(operation: operation)
                    }
                }
            }
        }
    }
}

private struct RecentActivityRow: View {
    let operation: LongOperation

    var body: some View {
        HStack(spacing: Spacing.s) {
            stateSymbol
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: operation.title)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            Text(operation.finishedAt ?? operation.startedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateSymbol: some View {
        switch operation.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    /// Host and state in words, so the state does not depend on the symbol color.
    private var detail: String {
        let state: String
        switch operation.state {
        case .running: state = operation.progressText ?? String(localized: "Running")
        case .succeeded(let text): state = text ?? String(localized: "Done")
        case .failed(let message): state = String(localized: "Failed: \(message)")
        case .cancelled: state = String(localized: "Cancelled")
        }
        guard let host = operation.hostName else { return state }
        return "\(host) · \(state)"
    }
}
