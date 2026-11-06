import SwiftUI
import AppCore
import DockerKit

/// The "Explain" button in the container header. It shows only for a
/// failing container and only while the feature is on.
struct ExplainFailureButton: View {
    let session: HostSession
    let container: ContainerSummary
    @AppStorage(ExplainSettings.enabledKey) private var enabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if enabled, ExplainEligibility.isFailing(container, reportsExitCode: session.reportsExitCodes) {
            Button {
                openWindow(id: ExplainTarget.windowID, value: ExplainTarget.container(hostID: session.host.id, containerID: container.id))
            } label: {
                Label(String(localized: "Explain"), systemImage: "apple.intelligence")
            }
            .help(String(localized: "Explain this failure with Apple Intelligence"))
        }
    }
}

/// The "Explain Failure…" item for context and overflow menus.
struct ExplainMenuItem: View {
    let session: HostSession
    let container: ContainerSummary
    @AppStorage(ExplainSettings.enabledKey) private var enabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if enabled, ExplainEligibility.isFailing(container, reportsExitCode: session.reportsExitCodes) {
            Button {
                openWindow(id: ExplainTarget.windowID, value: ExplainTarget.container(hostID: session.host.id, containerID: container.id))
            } label: {
                Label(String(localized: "Explain Failure…"), systemImage: "apple.intelligence")
            }
        }
    }
}

/// The "Explain" button of a failed build or compose up in Activity.
struct ExplainOperationButton: View {
    let operation: LongOperation
    @AppStorage(ExplainSettings.enabledKey) private var enabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if enabled, Self.applies(to: operation) {
            Button {
                openWindow(id: ExplainTarget.windowID, value: ExplainTarget.operation(id: operation.id))
            } label: {
                Label(String(localized: "Explain"), systemImage: "apple.intelligence")
            }
            .controlSize(.small)
            .help(String(localized: "Explain this failure with Apple Intelligence"))
        }
    }

    static func applies(to operation: LongOperation) -> Bool {
        guard case .failed = operation.state else { return false }
        return [.build, .composeUp, .pull].contains(operation.kind)
    }
}
