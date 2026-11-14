import SwiftUI
import AppCore

/// The long operations in the menu bar panel: running ones with progress,
/// elapsed time and Cancel, then the ones that finished a short time ago.
/// The rows come from ``MenuBarActivity``.
struct MenuBarActivitySection: View {
    let center: OperationCenter
    let showAll: () -> Void

    var body: some View {
        // Refresh now and then, so finished rows leave after their window.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let activity = MenuBarActivity(center: center, now: context.date)
            if activity.isVisible {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    MenuBarActivityHeader(runningCount: activity.runningCount, showAll: showAll)
                    ForEach(activity.running) { operation in
                        MenuBarRunningRow(operation: operation, center: center)
                    }
                    if activity.hiddenRunning > 0 {
                        Button(String(localized: "More running: \(activity.hiddenRunning)"), action: showAll)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    ForEach(activity.recent) { operation in
                        MenuBarFinishedRow(operation: operation, center: center)
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct MenuBarActivityHeader: View {
    let runningCount: Int
    let showAll: () -> Void

    var body: some View {
        HStack {
            Text("Activity")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(String(localized: "Show All"), action: showAll)
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

/// A running operation: icon, title, elapsed time, Cancel, host, bar and
/// the detail line. A cancel that needs a confirmation asks in the row,
/// because an alert would close the panel.
private struct MenuBarRunningRow: View {
    let operation: LongOperation
    let center: OperationCenter
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            bar
            detail
            if confirmCancel, operation.canCancel {
                MenuBarCancelConfirmation(
                    message: operation.cancelConfirmation ?? "",
                    stop: { confirmCancel = false; center.cancel(operation) },
                    keep: { confirmCancel = false }
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: operation.kind.systemImage)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(operation.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let host = operation.hostName {
                    Text(host).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(timerInterval: operation.startedAt...Date.distantFuture, countsDown: false)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Elapsed time"))
            cancelButton
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        if operation.isCancelling {
            Text("Stopping…").font(.caption).foregroundStyle(.secondary)
        } else if operation.canCancel {
            Button(String(localized: "Cancel")) {
                if operation.cancelConfirmation != nil { confirmCancel = true } else { center.cancel(operation) }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = operation.fraction {
            ProgressView(value: fraction).controlSize(.small)
        } else {
            ProgressView().progressViewStyle(.linear).controlSize(.small)
        }
    }

    private var detail: some View {
        Text(OperationRowText.detail(operation) ?? String(localized: "Working…"))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct MenuBarCancelConfirmation: View {
    let message: String
    let stop: () -> Void
    let keep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(String(localized: "Stop"), role: .destructive, action: stop)
                Button(String(localized: "Keep Running"), action: keep)
            }
            .controlSize(.small)
        }
    }
}

/// A finished operation: state, title, how long it ran, the error of a
/// failure, and Dismiss.
private struct MenuBarFinishedRow: View {
    let operation: LongOperation
    let center: OperationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ActivityStateIcon(state: operation.state)
                Text(operation.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let end = operation.finishedAt {
                    Text(MenuBarActivity.elapsed(from: operation.startedAt, to: end))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    center.dismiss(operation)
                } label: {
                    Label(String(localized: "Dismiss"), systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(String(localized: "Dismiss"))
            }
            if case .failed(let message) = operation.state {
                Text(ErrorPresentation.split(message).summary)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(message)
            }
        }
    }
}

/// The text under the bar of a running operation.
@MainActor
enum OperationRowText {
    /// "Layers: 3 of 7 · 12 MB of 45 MB", then the status when it adds to it.
    static func detail(_ operation: LongOperation) -> String? {
        let detail = operation.progress.detailText
        let status = operation.progressText?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (detail, status) {
        case let (detail?, status?) where !status.isEmpty && status != detail:
            return "\(detail) — \(status)"
        case let (detail?, _):
            return detail
        case let (nil, status?) where !status.isEmpty:
            return status
        default:
            return nil
        }
    }
}

extension OperationKind {
    /// The symbol of a kind in the menu bar rows.
    var systemImage: String {
        switch self {
        case .pull, .composePull: "arrow.down.circle"
        case .build: "hammer"
        case .composeUp: "square.stack.3d.up"
        case .composeDown: "square.stack.3d.down.right"
        case .clusterCreate: "circle.hexagongrid"
        case .machineCreate: "desktopcomputer"
        case .kernelInstall: "cpu"
        case .export: "square.and.arrow.up"
        case .trim: "scissors"
        case .brewInstall: "shippingbox"
        case .bulk: "checklist"
        case .kubernetes: "cube"
        case .storage: "externaldrive"
        case .other: "gearshape"
        }
    }
}

/// The menu bar item: the Gantry icon, and the count of running operations
/// next to it while work runs. A menu bar label shows an image and text, so
/// the count is text, not a color or an animation.
struct MenuBarLabel: View {
    let center: OperationCenter

    var body: some View {
        let count = center.runningCount
        HStack(spacing: 2) {
            Image("MenuBarIcon")
            if count > 0 {
                Text(count, format: .number).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MenuBarActivity.menuBarLabel(runningCount: count))
    }
}
