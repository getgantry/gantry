import SwiftUI
import AppKit
import AppCore
import DockerKit

/// The Storage pane of an apple host: where the data root is, its disk, the
/// space by category and per volume, and the move to another disk.
struct StoragePane: View {
    let session: HostSession

    @State private var overview: StorageOverview?
    @State private var loading = false
    @State private var showMove = false
    @State private var oldRoot = OldDataRootRecord.load()
    @State private var pendingAction: DestructiveAction?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .storage) { actions }
            Divider()
            ScrollView {
                cards
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(AppleSystemPane.storage.title)
        .task { await reload() }
        .onChange(of: StorageMonitor.shared.presence) { Task { await reload() } }
        .sheet(isPresented: $showMove, onDismiss: { Task { await reload() } }) {
            if let overview {
                MoveDataRootSheet(session: session, overview: overview) { Task { await reload() } }
            }
        }
        .destructiveConfirmation($pendingAction) { action, _ in
            await deleteOldRoot(action.targets.first)
        }
    }

    @ViewBuilder
    private var cards: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let errorText {
                AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
            }
            if let overview {
                StorageLocationCard(overview: overview)
                if let usage = overview.usage {
                    StorageUsageCard(usage: usage)
                    StorageVolumesCard(volumes: usage.volumes)
                }
                if let oldRoot, oldRoot != overview.configuredRoot.effectivePath {
                    oldCopyCard(oldRoot)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
            FolderVolumesCard(session: session)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            Button {
                showMove = true
            } label: {
                Label(String(localized: "Move to Another Disk…"), systemImage: "externaldrive.badge.plus")
            }
            .disabled(overview?.usage == nil || loading)
            Button {
                Task { await reload() }
            } label: {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
    }

    private func oldCopyCard(_ path: String) -> some View {
        AppleSystemCard(title: String(localized: "Old Copy"), systemImage: "clock.arrow.circlepath") {
            Text("The data was moved. The old copy is still at this location:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: path).font(.callout.monospaced()).textSelection(.enabled)
            HStack {
                Button(String(localized: "Show in Finder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
                Button(String(localized: "Delete Old Copy…"), role: .destructive) {
                    pendingAction = .deleteOldDataRoot(path)
                }
                Button(String(localized: "Keep")) {
                    OldDataRootRecord.save(nil)
                    oldRoot = nil
                }
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let status = try? await AppleContainerControl.systemStatus(cliOverride: session.appleCLIOverride)
        overview = await StorageOverview.load(serviceRoot: status?.appRoot)
        oldRoot = OldDataRootRecord.load()
    }

    private func deleteOldRoot(_ path: String?) async {
        guard let path, let overview else { return }
        let mover = DataRootMover(environment: LiveDataRootMoveEnvironment(cliOverride: session.appleCLIOverride))
        do {
            try await mover.deleteOldRoot(path, activeRoot: overview.configuredRoot.effectivePath)
            OldDataRootRecord.save(nil)
            oldRoot = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await reload()
    }
}

/// The data root, its disk, and how the CLI finds it.
struct StorageLocationCard: View {
    let overview: StorageOverview

    var body: some View {
        AppleSystemCard(title: String(localized: "Location"), systemImage: "folder") {
            LabeledContent(String(localized: "Data folder")) {
                Text(verbatim: overview.configuredRoot.effectivePath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            if let disk = overview.disk {
                StorageDiskSummary(disk: disk)
            } else {
                Label(missingText, systemImage: "externaldrive.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if overview.rootMismatch, let serviceRoot = overview.serviceRoot {
                Label(String(localized: "The services run on \(serviceRoot) now. Restart them to use the folder above."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            StorageCommandNote(root: overview.configuredRoot)
        }
    }

    private var missingText: String {
        let name = StoragePaths.volumeName(of: overview.configuredRoot.effectivePath) ?? overview.configuredRoot.effectivePath
        return StorageBlock(disks: [name]).hostMessage
    }
}

/// Tells how to start the services on the same root from Terminal.
struct StorageCommandNote: View {
    let root: AppleDataRoot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(verbatim: root.startCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(root.startCommand, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy Command"))
                .accessibilityLabel(String(localized: "Copy Command"))
            }
        }
    }

    private var note: String {
        root.isCustom
            ? String(localized: "The container command does not remember this folder. Gantry starts the services with it each time. If you start them in Terminal, use this command:")
            : String(localized: "The services use the default folder. Start them in Terminal with:")
    }
}

/// Name, format, space and placement of a disk.
struct StorageDiskSummary: View {
    let disk: StorageDisk

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(String(localized: "Disk")) {
                Label(disk.name, systemImage: StoragePlacementText.systemImage(disk.placement))
            }
            LabeledContent(String(localized: "Format")) { Text(verbatim: disk.formatDescription) }
            LabeledContent(String(localized: "Type")) { Text(StoragePlacementText.title(disk.placement)) }
            LabeledContent(String(localized: "Free")) {
                Text("\(StorageFormat.bytes(disk.availableBytes)) of \(StorageFormat.bytes(disk.totalBytes))")
            }
            if disk.totalBytes > 0 {
                ProgressView(value: Double(disk.totalBytes - disk.availableBytes), total: Double(disk.totalBytes))
                    .accessibilityLabel(String(localized: "Used space"))
            }
        }
        .font(.callout)
    }
}

/// Texts and symbols of a disk placement.
enum StoragePlacementText {
    static func title(_ placement: StoragePlacement) -> String {
        switch placement {
        case .internal: String(localized: "Internal")
        case .external: String(localized: "External")
        case .removable: String(localized: "Removable")
        case .network: String(localized: "Network")
        }
    }

    static func systemImage(_ placement: StoragePlacement) -> String {
        switch placement {
        case .internal: "internaldrive"
        case .external, .removable: "externaldrive"
        case .network: "server.rack"
        }
    }
}

/// Space by category: allocated bytes, with the apparent size when the
/// disk images are sparse.
struct StorageUsageCard: View {
    let usage: StorageUsage

    var body: some View {
        AppleSystemCard(title: String(localized: "Space Used"), systemImage: "chart.bar") {
            ForEach(StorageCategory.allCases) { category in
                row(category)
            }
            Divider()
            LabeledContent(String(localized: "Total")) {
                Text(StorageFormat.bytes(usage.total.allocated)).monospacedDigit().bold()
            }
            Text("Sizes are the space on the disk. Disk images are sparse, so their full size can be larger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ category: StorageCategory) -> some View {
        let size = usage.size(of: category)
        return LabeledContent {
            HStack(spacing: 6) {
                Text(StorageFormat.bytes(size.allocated)).monospacedDigit()
                if size.apparent > size.allocated * 2, size.apparent > 0 {
                    Text("(up to \(StorageFormat.bytes(size.apparent)))")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(category.title, systemImage: category.systemImage)
        }
        .font(.callout)
    }
}

/// Each named volume and the size of its disk image.
struct StorageVolumesCard: View {
    let volumes: [StorageVolumeUsage]

    var body: some View {
        AppleSystemCard(title: String(localized: "Volumes"), systemImage: "externaldrive") {
            if volumes.isEmpty {
                Text("No named volumes.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(volumes) { volume in
                LabeledContent(volume.name) {
                    Text("\(StorageFormat.bytes(volume.size.allocated)) on disk, \(StorageFormat.bytes(volume.size.apparent)) image")
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}
