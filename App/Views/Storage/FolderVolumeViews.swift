import SwiftUI
import AppKit
import AppCore
import DockerKit

/// The folder volumes of an apple host, for the Storage pane.
struct FolderVolumesCard: View {
    let session: HostSession

    var body: some View {
        let volumes = StorageMonitor.shared.folderVolumes.volumes(for: session.host.id)
        if session.host.isAppleContainer {
            AppleSystemCard(title: String(localized: "Folders on Disks"), systemImage: "folder.badge.gearshape") {
                if volumes.isEmpty {
                    Text("No folder volumes. Use New Volume in Volumes to keep a volume in a folder on any disk.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(volumes) { volume in
                    FolderVolumeRow(session: session, volume: volume)
                }
            }
        }
    }
}

/// The folder volumes as a section of the Volumes list (apple hosts).
struct FolderVolumeSection: View {
    let session: HostSession

    var body: some View {
        let volumes = StorageMonitor.shared.folderVolumes.volumes(for: session.host.id)
        if session.host.isAppleContainer, !volumes.isEmpty {
            Section(String(localized: "Folders on Disks")) {
                ForEach(volumes) { volume in
                    FolderVolumeRow(session: session, volume: volume)
                }
            }
        }
    }
}

/// One folder volume: name, path, disk state and its actions.
struct FolderVolumeRow: View {
    let session: HostSession
    let volume: FolderVolume

    @State private var move: VolumeMove?
    @State private var forget: DestructiveAction?

    private var connected: Bool { StorageMonitor.shared.presence.isConnected(volume.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connected ? "folder.fill" : "externaldrive.trianglebadge.exclamationmark")
                .foregroundStyle(connected ? Color.accentColor : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).font(.headline)
                Text(verbatim: volume.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !connected, let disk = StorageMonitor.shared.presence.missingDisk(for: volume.path) {
                    Text(StorageBlock(disks: [disk]).message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            menu
        }
        .padding(.vertical, 2)
        .contextMenu { items }
        .sheet(item: $move) { VolumeTransferSheet(session: session, move: $0) }
        .destructiveConfirmation($forget) { _, _ in
            try? StorageMonitor.shared.folderVolumes.remove(name: volume.name, hostID: session.host.id)
        }
    }

    private var menu: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Actions"))
        .accessibilityLabel(String(localized: "Actions for \(volume.name)"))
    }

    @ViewBuilder
    private var items: some View {
        Button(String(localized: "Show in Finder")) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: volume.path)
        }
        .disabled(!connected)
        Button(String(localized: "Move into a Named Volume…")) { move = .toNamed(volume) }
            .disabled(!connected)
        Button(String(localized: "Export to Archive…")) {
            VolumeArchiveActions.export(session: session, volume: .folder(volume.path), name: volume.name)
        }
        .disabled(!connected)
        Divider()
        Button(String(localized: "Remove from Gantry…"), role: .destructive) {
            forget = .forgetFolderVolume(volume.name)
        }
    }
}
