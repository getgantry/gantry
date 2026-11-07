import SwiftUI

/// The sidebar section in front, published by the main window so the menu
/// commands (⌘N, ⌘R, ⇧⌘P) act on it. A nil `section` means the dashboard.
struct FocusedSection: Equatable {
    var section: HostSection?

    /// The ⌘N item for this section, or nil when the section creates nothing.
    var newItemTitle: String? {
        switch section {
        case .containers: String(localized: "New Container…")
        case .images: String(localized: "Build Image…")
        case .volumes: String(localized: "New Volume…")
        case .networks: String(localized: "New Network…")
        case .machines: String(localized: "New Machine…")
        case .clusters: String(localized: "New Cluster…")
        default: nil
        }
    }
}

extension FocusedValues {
    @Entry var gantrySection: FocusedSection?
}

/// A menu command aimed at one section. Posted with the section as the
/// notification object; only the view of that section acts on it.
enum SectionCommand {
    case newItem
    case refresh
    case pullImage
    case cleanup

    var notification: Notification.Name {
        switch self {
        case .newItem: .gantryNewItem
        case .refresh: .gantryRefreshSection
        case .pullImage: .gantryPullImage
        case .cleanup: .gantryCleanup
        }
    }

    @MainActor
    func post(_ section: HostSection?) {
        NotificationCenter.default.post(name: notification, object: section)
    }
}

/// A section command for one host, sent by the command palette before the
/// section view may exist. The view of that host takes it when it appears,
/// or at once if it is already shown.
@MainActor
enum PendingSectionCommand {
    private struct Request {
        let command: SectionCommand
        let section: HostSection
        let hostID: UUID
        let date: Date
    }

    private static var request: Request?

    static func send(_ command: SectionCommand, _ section: HostSection, hostID: UUID) {
        request = Request(command: command, section: section, hostID: hostID, date: .now)
        NotificationCenter.default.post(name: .gantryPendingSectionCommand, object: nil)
    }

    /// Removes and reports a matching request. A request older than a few
    /// seconds is stale: the view it was for did not appear.
    static func take(_ command: SectionCommand, _ section: HostSection, hostID: UUID) -> Bool {
        guard let request, request.command == command, request.section == section,
              request.hostID == hostID else { return false }
        self.request = nil
        return Date.now.timeIntervalSince(request.date) < 5
    }
}

extension View {
    /// Runs `action` when the menu sends `command` to `section`. With `host`,
    /// it also runs for a palette request aimed at that host.
    func onSectionCommand(
        _ command: SectionCommand,
        _ section: HostSection,
        host: UUID? = nil,
        perform action: @escaping () -> Void
    ) -> some View {
        modifier(SectionCommandReceiver(command: command, section: section, host: host, action: action))
    }
}

private struct SectionCommandReceiver: ViewModifier {
    let command: SectionCommand
    let section: HostSection
    let host: UUID?
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: command.notification)) { note in
                if note.object as? HostSection == section { action() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gantryPendingSectionCommand)) { _ in
                takePending()
            }
            .task(id: host) { takePending() }
    }

    private func takePending() {
        guard let host, PendingSectionCommand.take(command, section, hostID: host) else { return }
        action()
    }
}

/// The Docker menu: section-aware New and Refresh, Refresh All Hosts, Pull,
/// and the file-based flows.
struct SectionCommands: Commands {
    @FocusedValue(\.gantrySection) private var focused
    let openComposeFile: () -> Void
    let openDockerfile: () -> Void

    var body: some Commands {
        CommandMenu("Docker") {
            Button(focused?.newItemTitle ?? String(localized: "New…")) {
                SectionCommand.newItem.post(focused?.section)
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(focused?.newItemTitle == nil)

            Button("Pull Image…") {
                SectionCommand.pullImage.post(.images)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(focused?.section != .images)

            Divider()

            Button("Refresh") {
                SectionCommand.refresh.post(focused?.section)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(focused == nil)

            Button("Refresh All Hosts") {
                NotificationCenter.default.post(name: .gantryRefreshAll, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Open Compose File…", action: openComposeFile)
                .keyboardShortcut("o", modifiers: .command)

            Button("Build Image from Dockerfile…", action: openDockerfile)
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                NotificationCenter.default.post(name: .gantryShowPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
        }
    }
}
