import SwiftUI
import AppCore

/// Cause, evidence, next steps, and what Gantry sent.
struct ExplainResultView: View {
    let explanation: FailureExplanation
    let subject: ExplainSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ExplainCauseSection(explanation: explanation)
            if !explanation.evidence.isEmpty {
                ExplainEvidenceSection(evidence: explanation.evidence)
            }
            if !explanation.steps.isEmpty {
                ExplainStepsSection(steps: explanation.steps, hostID: subject.hostID)
            }
            Text("The model can be wrong. Check the evidence before you act.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let context = subject.controller.context {
                ExplainSentContext(text: context.render())
            }
        }
    }
}

private struct ExplainCauseSection: View {
    let explanation: FailureExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Likely Cause").font(.headline)
                Spacer()
                ExplainConfidenceBadge(confidence: explanation.confidence)
            }
            Text(explanation.cause)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ExplainConfidenceBadge: View {
    let confidence: FailureExplanation.Confidence

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch confidence {
        case .low: String(localized: "Low confidence")
        case .medium: String(localized: "Medium confidence")
        case .high: String(localized: "High confidence")
        }
    }

    private var tint: Color {
        switch confidence {
        case .low: .orange
        case .medium: .yellow
        case .high: .green
        }
    }
}

private struct ExplainEvidenceSection: View {
    let evidence: [FailureExplanation.Evidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Evidence").font(.headline)
            ForEach(evidence) { line in
                ExplainEvidenceRow(evidence: line)
            }
        }
    }
}

private struct ExplainEvidenceRow: View {
    let evidence: FailureExplanation.Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(evidence.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
            if !evidence.isQuoted {
                Label(String(localized: "Not found in the logs Gantry sent"), systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ExplainStepsSection: View {
    let steps: [FailureExplanation.Step]
    let hostID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Next Steps").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                ExplainStepRow(number: index + 1, step: step, hostID: hostID)
            }
        }
    }
}

/// A step with its command. The command is only copied or typed into a
/// terminal; Gantry never runs it.
private struct ExplainStepRow: View {
    let number: Int
    let step: FailureExplanation.Step
    let hostID: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(number). \(step.title)")
                .fixedSize(horizontal: false, vertical: true)
            if let command = step.command {
                commandBox(command)
                if step.isDestructive {
                    Label(String(localized: "This command stops or deletes something. Read it before you run it."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copyToPasteboard(command)
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Copy"))
            Button {
                openWindow(id: ExplainTerminalRequest.windowID, value: ExplainTerminalRequest(hostID: hostID, command: command))
            } label: {
                Label(String(localized: "Run in Terminal…"), systemImage: "terminal")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Open a terminal with this command typed in. It does not run until you press Return."))
        }
        .padding(6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
    }
}

/// The exact text Gantry sent, after redaction.
private struct ExplainSentContext: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(String(localized: "What Gantry Sent"), isExpanded: $expanded) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .font(.callout)
    }
}
