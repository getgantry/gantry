import SwiftUI
import AppCore

/// A red inline message under a form field; renders nothing for nil.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// A warning mark at the end of a port row that has a problem.
struct PortIssueIcon: View {
    let issue: ContainerForm.PortIssue?

    var body: some View {
        if let issue {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(issue.message)
                .accessibilityLabel(issue.message)
        }
    }
}

/// A container that a create sheet started and that stopped at once.
struct StartedContainerExit: Identifiable {
    var id: String { containerID }
    let hostID: UUID
    let containerID: String
    let name: String
    /// nil where the runtime does not report it.
    let exitCode: Int?

    var title: String {
        if let exitCode { return String(localized: "Exited (code \(exitCode))") }
        return String(localized: "Exited")
    }
}

extension View {
    /// The alert a create sheet shows when its container stopped right after
    /// it started. "Show Logs" closes the sheet and opens the container's Logs
    /// tab; "Close" only closes the sheet.
    func startedContainerExitAlert(
        _ exit: Binding<StartedContainerExit?>,
        session: HostSession,
        dismiss: @escaping () -> Void
    ) -> some View {
        alert(
            exit.wrappedValue?.title ?? "",
            isPresented: Binding(presence: exit),
            presenting: exit.wrappedValue
        ) { stopped in
            Button("Show Logs") {
                dismiss()
                ContainerTabRequest.open(.logs, hostID: stopped.hostID, containerID: stopped.containerID)
            }
            Button("Close", role: .cancel) { dismiss() }
        } message: { stopped in
            Text("“\(stopped.name)” stopped right after it started. Its logs usually show why.")
        }
    }
}

/// Opens a container's detail on a given tab. The tab request is kept as a
/// pending value, because the detail view may not exist yet when the
/// navigation notification goes out (a notification alone races with it).
@MainActor
enum ContainerTabRequest {
    enum Tab: Equatable {
        case logs
        case debugShell
    }

    private(set) static var pending: (containerID: String, tab: Tab)?

    /// Records the tab, then navigates to the container.
    static func open(_ tab: Tab, hostID: UUID, containerID: String) {
        pending = (containerID, tab)
        NotificationCenter.default.post(
            name: .gantrySelectContainer,
            object: ContainerJump(hostID: hostID, containerID: containerID)
        )
        if tab == .debugShell {
            NotificationCenter.default.post(name: .gantryOpenDebugShell, object: containerID)
        }
    }

    /// The pending tab for this container, left in place.
    static func peek(_ containerID: String) -> Tab? {
        pending?.containerID == containerID ? pending?.tab : nil
    }

    /// The pending tab for this container, removed.
    static func take(_ containerID: String) -> Tab? {
        guard let tab = peek(containerID) else { return nil }
        pending = nil
        return tab
    }
}
