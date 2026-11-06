import SwiftUI
import AppKit
import AppCore

/// The window content: resolves the target, then shows the panel.
struct ExplainWindow: View {
    @Environment(AppModel.self) private var model
    let target: ExplainTarget?
    @State private var subject: ExplainSubject?

    var body: some View {
        Group {
            if let subject {
                ExplainPanel(subject: subject)
            } else {
                ContentUnavailableView(
                    String(localized: "Nothing to Explain"),
                    systemImage: "questionmark.circle",
                    description: Text("The container or operation is no longer there.")
                )
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 620)
        .navigationTitle(String(localized: "Explain Failure"))
        .task(id: target) {
            guard let target, let resolved = ExplainFactory.subject(for: target, model: model) else { return }
            subject = resolved
            resolved.controller.start()
        }
        .onDisappear { subject?.controller.cancel() }
    }
}

/// Header, privacy note, then the state of the analysis.
struct ExplainPanel: View {
    let subject: ExplainSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExplainHeader(subject: subject)
                .padding()
            Divider()
            ScrollView {
                ExplainPhaseView(subject: subject)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ExplainFooter(subject: subject)
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
    }
}

private struct ExplainHeader: View {
    let subject: ExplainSubject

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "apple.intelligence")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(subject.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }
}

/// The note about where the analysis runs and what Gantry hides.
private struct ExplainPrivacyNote: View {
    let model: ExplainModelKind?

    var body: some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: model == .privateCloud ? "lock.icloud" : "lock.laptopcomputer")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        if model == .privateCloud {
            return String(localized: "Analysis runs on Apple Private Cloud Compute. Gantry hides environment values and secret-like text before it sends the logs.")
        }
        return String(localized: "Analysis runs on this Mac. Gantry hides environment values and secret-like text before it sends the logs to the model.")
    }
}

private struct ExplainFooter: View {
    let subject: ExplainSubject

    var body: some View {
        HStack {
            ExplainPrivacyNote(model: subject.controller.model)
            Spacer(minLength: 8)
            ExplainCopyPromptButton(subject: subject)
            Button(String(localized: "Try Again")) { subject.controller.start() }
                .disabled(subject.controller.isWorking)
        }
    }
}

struct ExplainCopyPromptButton: View {
    let subject: ExplainSubject

    var body: some View {
        Button {
            Task { copyToPasteboard(await subject.fallbackPrompt()) }
        } label: {
            Label(String(localized: "Copy as Prompt"), systemImage: "text.badge.star")
        }
        .help(String(localized: "Copy a prompt for another AI assistant"))
    }
}

/// One view per phase of the controller.
private struct ExplainPhaseView: View {
    let subject: ExplainSubject

    var body: some View {
        switch subject.controller.phase {
        case .idle, .gathering:
            ExplainProgress(text: String(localized: "Collecting logs and details…"))
        case .thinking:
            ExplainProgress(text: String(localized: "Analyzing the failure…"))
        case .unavailable(let reason):
            ExplainUnavailableView(reason: reason, subject: subject)
        case .failed(let message):
            ExplainFailedView(message: message)
        case .done(let explanation):
            ExplainResultView(explanation: explanation, subject: subject)
        }
    }
}

private struct ExplainProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct ExplainFailedView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "The model could not explain this failure."), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Try again, or copy a prompt for another AI assistant.")
                .font(.callout)
        }
    }
}

private struct ExplainUnavailableView: View {
    let reason: ExplainUnavailableReason
    let subject: ExplainSubject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(ExplainTexts.title(for: reason), systemImage: "apple.intelligence")
                .font(.headline)
            Text(ExplainTexts.detail(for: reason))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ExplainCopyPromptButton(subject: subject)
                    .buttonStyle(.borderedProminent)
                if reason == .turnedOff {
                    SettingsLink { Text("Open Settings") }
                }
            }
        }
    }
}

/// User-facing texts for availability.
enum ExplainTexts {
    static func title(for reason: ExplainUnavailableReason) -> String {
        reason == .turnedOff
            ? String(localized: "Explain is turned off")
            : String(localized: "Apple Intelligence is not available")
    }

    static func detail(for reason: ExplainUnavailableReason) -> String {
        switch reason {
        case .turnedOff:
            String(localized: "Turn on Explain in Settings > Agents. You can copy a prompt for another AI assistant instead.")
        case .deviceNotEligible:
            String(localized: "This Mac does not support Apple Intelligence. You can copy a prompt for another AI assistant instead.")
        case .appleIntelligenceNotEnabled:
            String(localized: "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri, then try again. You can copy a prompt for another AI assistant instead.")
        case .modelNotReady:
            String(localized: "The Apple Intelligence model is not ready yet. It can still be downloading. Try again later, or copy a prompt for another AI assistant.")
        case .unsupportedLanguage:
            String(localized: "Apple Intelligence does not support the language of Gantry. You can copy a prompt for another AI assistant instead.")
        case .other(let detail):
            String(localized: "Apple Intelligence reports: \(detail). You can copy a prompt for another AI assistant instead.")
        }
    }

    static func status(_ availability: ExplainAvailability) -> String {
        switch availability {
        case .available(.onDevice): String(localized: "Ready: on-device model")
        case .available(.privateCloud): String(localized: "Ready: Private Cloud Compute")
        case .unavailable(let reason): detail(for: reason)
        }
    }
}
