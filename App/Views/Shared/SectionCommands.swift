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

    var notification: Notification.Name {
        switch self {
        case .newItem: .gantryNewItem
        case .refresh: .gantryRefreshSection
        case .pullImage: .gantryPullImage
        }
    }

    @MainActor
    func post(_ section: HostSection?) {
        NotificationCenter.default.post(name: notification, object: section)
    }
}

extension View {
    /// Runs `action` when the menu sends `command` to `section`.
    func onSectionCommand(
        _ command: SectionCommand,
        _ section: HostSection,
        perform action: @escaping () -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: command.notification)) { note in
            if note.object as? HostSection == section { action() }
        }
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
    }
}
