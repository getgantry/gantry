import SwiftUI
import AppCore
import DockerKit

/// The summary, steps and log of one build.
struct BuildDetailView: View {
    let record: BuildRecord
    var loading = false
    var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                BuildDetailHeader(record: record)
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let message = record.errorMessage, !message.isEmpty {
                    BuildErrorBox(message: message)
                }
                DetailSection("Summary") { BuildFacts(record: record) }
                if !record.steps.isEmpty {
                    DetailSection("Steps") { BuildStepsList(steps: record.steps) }
                }
                if loading {
                    ProgressView().controlSize(.small)
                } else if !record.log.isEmpty {
                    DetailSection("Log") { BuildLogText(log: record.log, truncated: record.logTruncated) }
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BuildDetailHeader: View {
    let record: BuildRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(verbatim: record.name.isEmpty ? record.id : record.name)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)
            StatusBadge(
                text: BuildStatusStyle.title(record.status),
                systemImage: BuildStatusStyle.symbol(record.status),
                tint: BuildStatusStyle.tint(record.status)
            )
        }
    }
}

private struct BuildErrorBox: View {
    let message: String

    var body: some View {
        Text(verbatim: message)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .lineLimit(8)
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 8))
            .accessibilityLabel(Text("Error: \(message)"))
    }
}

private struct BuildFacts: View {
    let record: BuildRecord

    var body: some View {
        let summary = record.summary
        FactGrid {
            Fact("Source", BuildStatusStyle.source(record.source))
            Fact("Started", record.startedAt.formatted(date: .abbreviated, time: .standard))
            if let duration = BuildStatusStyle.duration(record.duration) { Fact("Duration", duration) }
            if summary.total > 0 {
                Fact("Steps", String(localized: "\(summary.total) steps"))
                Fact("Cached", String(localized: "\(summary.cached) cached", comment: "Build steps that came from the build cache"))
                Fact("Executed", "\(summary.run)")
            }
            if let dockerfile = record.dockerfile { Fact("Dockerfile", dockerfile, monospaced: true) }
            if let context = record.contextPath { Fact("Context", context, monospaced: true) }
            if let target = record.target { Fact("Target stage", target, monospaced: true) }
            if record.noCache { Fact("Build without cache", String(localized: "Yes")) }
            if !record.buildArgNames.isEmpty {
                Fact("Build args", record.buildArgNames.joined(separator: ", "), monospaced: true)
            }
            if let image = record.imageID {
                Fact("Image", String(image.prefix(19)), monospaced: true, copyText: image)
            }
        }
    }
}

private struct BuildStepsList: View {
    let steps: [BuildStep]
    @State private var showInternal = false

    private var shown: [BuildStep] { showInternal ? steps : steps.filter { !$0.isInternal } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { step in BuildStepRow(step: step) }
            if steps.contains(where: \.isInternal) {
                Toggle("Show Internal Steps", isOn: $showInternal)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
    }
}

private struct BuildStepRow: View {
    let step: BuildStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Label(stateTitle, systemImage: symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(tint)
            Text(verbatim: step.name)
                .font(.callout.monospaced())
                .foregroundStyle(step.isInternal ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.xs)
            Text(verbatim: stateTitle).font(.caption).foregroundStyle(.secondary)
            if let duration = BuildStatusStyle.duration(step.duration) {
                Text(verbatim: duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        switch step.state {
        case .run: String(localized: "Executed", comment: "A build step that ran")
        case .cached: String(localized: "Cached", comment: "A build step that came from the build cache")
        case .failed: String(localized: "Failed")
        case .unknown: String(localized: "No Result", comment: "A build step without a result in the log")
        }
    }

    private var symbol: String {
        switch step.state {
        case .run: "play.circle"
        case .cached: "archivebox"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch step.state {
        case .run: .blue
        case .cached: .secondary
        case .failed: .red
        case .unknown: .secondary
        }
    }
}

private struct BuildLogText: View {
    let log: String
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if truncated {
                Text("Gantry kept only the end of this log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: log)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
        }
    }
}
