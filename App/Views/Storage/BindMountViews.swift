import SwiftUI
import AppCore
import DockerKit

/// A menu next to a host path field: named volumes, folder volumes, and the
/// external disks to pick a folder on.
struct BindSourceMenu: View {
    let session: HostSession
    let onPick: (String) -> Void
    @State private var external: [StorageDisk] = []

    var body: some View {
        Menu {
            namedVolumes
            folderVolumes
            disks
        } label: {
            Image(systemName: "externaldrive")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Choose a volume or a disk"))
        .accessibilityLabel(String(localized: "Choose a volume or a disk"))
        .task(id: StorageMonitor.shared.presence) {
            external = session.usesLocalPaths ? await StorageCheckLoader.externalDisks() : []
        }
    }

    @ViewBuilder
    private var namedVolumes: some View {
        if !session.volumes.isEmpty {
            Section(String(localized: "Volumes")) {
                ForEach(session.volumes) { volume in
                    Button(volume.name) { onPick(volume.name) }
                }
            }
        }
    }

    @ViewBuilder
    private var folderVolumes: some View {
        let folders = StorageMonitor.shared.folderVolumes.volumes(for: session.host.id)
        if !folders.isEmpty {
            Section(String(localized: "Folders on Disks")) {
                ForEach(folders) { folder in
                    Button(folder.name) { onPick(folder.path) }
                        .disabled(!StorageMonitor.shared.presence.isConnected(folder.path))
                }
            }
        }
    }

    @ViewBuilder
    private var disks: some View {
        if session.usesLocalPaths {
            if !external.isEmpty {
                Section(String(localized: "Folder on a Disk")) {
                    ForEach(external) { disk in
                        Button("\(disk.name) (\(StoragePlacementText.title(disk.placement)))") {
                            if let url = StorageFolderPanel.chooseFolder(prompt: String(localized: "Choose"), start: disk.mountPath) {
                                onPick(url.path)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Warnings for host folders on removable disks, disks that ignore
/// owners, network disks, and disks that are not connected.
struct BindMountWarnings: View {
    let session: HostSession
    let paths: [String]
    @State private var findings: [(path: String, check: StorageCheck)] = []

    var body: some View {
        Group {
            if session.usesLocalPaths {
                ForEach(findings, id: \.path) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: finding.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        StorageIssueList(check: finding.check)
                    }
                }
            }
        }
        .task(id: paths) {
            findings = await StorageCheckLoader.bindMounts(paths: paths, presence: StorageMonitor.shared.presence)
        }
    }
}
