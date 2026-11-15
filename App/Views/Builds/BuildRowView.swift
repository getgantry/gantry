import SwiftUI
import AppCore
import DockerKit

/// The look of a build status: a word and a symbol, never color only.
enum BuildStatusStyle {
    static func title(_ status: BuildStatus) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .interrupted: String(localized: "Interrupted")
        }
    }

    static func symbol(_ status: BuildStatus) -> String {
        switch status {
        case .running: "hourglass"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ status: BuildStatus) -> Color {
        switch status {
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        case .interrupted: .orange
        }
    }

    static func source(_ source: BuildSource) -> String {
        switch source {
        case .gantry: String(localized: "Gantry")
        case .buildx: String(localized: "BuildKit")
        }
    }

    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        return Duration.milliseconds(Int64((seconds * 1000).rounded())).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                   maximumUnitCount: 2, fractionalPart: .show(length: seconds < 10 ? 1 : 0))
        )
    }

    /// "9 steps, 3 cached", or nil when the record has no steps.
    static func steps(_ summary: BuildStepSummary) -> String? {
        guard summary.total > 0 else { return nil }
        let total = String(localized: "\(summary.total) steps")
        let cached = String(localized: "\(summary.cached) cached", comment: "Build steps that came from the build cache")
        return total + ", " + cached
    }
}

/// One build in the list.
struct BuildRowView: View {
    let record: BuildRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.name.isEmpty ? record.id : record.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if record.status == .running {
            ProgressView().controlSize(.small)
                .accessibilityLabel(BuildStatusStyle.title(record.status))
        } else {
            Image(systemName: BuildStatusStyle.symbol(record.status))
                .foregroundStyle(BuildStatusStyle.tint(record.status))
                .accessibilityLabel(BuildStatusStyle.title(record.status))
        }
    }

    private var details: String {
        var parts = [
            BuildStatusStyle.title(record.status),
            BuildStatusStyle.source(record.source),
            record.startedAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if let duration = BuildStatusStyle.duration(record.duration) { parts.append(duration) }
        if let steps = BuildStatusStyle.steps(record.summary) { parts.append(steps) }
        return parts.joined(separator: " · ")
    }
}
