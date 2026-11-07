import SwiftUI
import AppKit
import AppCore
import DockerKit

/// What a volume move does.
enum VolumeMove: Identifiable {
    /// A named volume to a new folder on a disk.
    case toFolder(volume: String)
    /// A folder volume (apple hosts) into a new named volume.
    case toNamed(FolderVolume)

    var id: String {
        switch self {
        case .toFolder(let name): "folder:" + name
        case .toNamed(let volume): "named:" + volume.name
        }
    }

    var sourceName: String {
        switch self {
        case .toFolder(let name): name
        case .toNamed(let volume): volume.name
        }
    }

    var source: VolumeEndpoint {
        switch self {
        case .toFolder(let name): .named(name)
        case .toNamed(let volume): .folder(volume.path)
        }
    }
}

/// Copies a volume to a new place, then makes the containers that use it
/// again after a confirmation. The old data stays.
struct VolumeTransferSheet: View {
    let session: HostSession
    let move: VolumeMove

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var parent = ""
    @State private var operation: LongOperation?
    @State private var destination: VolumeEndpoint?
    @State private var confirm: DestructiveAction?
    @State private var switched = false

    private var users: [ContainerSummary] { VolumeTransferPlan.users(of: move.source, in: session.containers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.bold))
            if operation == nil { form } else { progress }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { newName = move.sourceName + "-moved" }
        .destructiveConfirmation($confirm) { _, _ in await switchContainers() }
    }

    private var title: String {
        switch move {
        case .toFolder: String(localized: "Move “\(move.sourceName)” to a Disk")
        case .toNamed: String(localized: "Move “\(move.sourceName)” into a Named Volume")
        }
    }

    @ViewBuilder
    private var form: some View {
        TextField(String(localized: "New volume name"), text: $newName).textFieldStyle(.roundedBorder)
        if case .toFolder = move { FolderLocationField(parent: $parent, name: newName) }
        Text("Gantry copies the files with a short-lived helper container. The old volume stays until you remove it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !users.isEmpty {
            Text("\(users.count) containers use this volume. After the copy, Gantry can make them again with the new volume.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let operation {
            switch operation.state {
            case .running:
                ProgressView(operation.progressText ?? String(localized: "Copying…"))
            case .succeeded:
                Label(String(localized: "The copy is complete."), systemImage: "checkmark.circle")
                if switched {
                    Text("The containers use the new volume. Remove the old one when you are sure.").font(.callout)
                } else if !users.isEmpty {
                    Button(String(localized: "Recreate Containers…")) {
                        confirm = .switchVolume(move.sourceName, containers: users)
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .cancelled:
                Label(String(localized: "Cancelled."), systemImage: "xmark.circle")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if operation == nil {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Copy")) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            } else {
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(operation?.state.isFinished != true)
            }
        }
    }

    private var canStart: Bool {
        guard FolderVolumeRules.isValidName(newName) else { return false }
        if case .toFolder = move { return !parent.isEmpty }
        return true
    }

    private func start() {
        let name = newName, parent = parent, move = move, session = session
        operation = LongOperationRunner.run(
            .storage, title: String(localized: "Copy volume \(move.sourceName)"), session: session
        ) { op in
            op.update(progress: String(localized: "Making the new volume"))
            let target = try await Self.makeTarget(session: session, move: move, name: name, parent: parent)
            op.update(progress: String(localized: "Copying the files"))
            try await session.copyVolumeData(from: move.source, to: target)
            await session.refreshVolumes()
            destination = target
            return String(localized: "Copied to \(target.mountSource).")
        }
    }

    /// Makes the new, empty volume or folder.
    private static func makeTarget(session: HostSession, move: VolumeMove, name: String, parent: String) async throws -> VolumeEndpoint {
        switch move {
        case .toFolder:
            try await session.createFolderVolume(name: name, parent: parent)
            // Docker records a bind volume; apple mounts the folder itself.
            return session.host.isAppleContainer ? .folder(FolderVolumeRules.folder(named: name, in: parent)) : .named(name)
        case .toNamed:
            guard await session.createVolume(name: name) != nil else {
                throw OperationFailure(session.lastError ?? String(localized: "Could not create the volume."))
            }
            return .named(name)
        }
    }

    private func switchContainers() async {
        guard let destination else { return }
        for container in users {
            do {
                try await session.recreate(container, replacing: move.source, with: destination)
            } catch {
                session.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        switched = true
    }
}

/// Export and import of a volume as a tar archive on any disk.
@MainActor
enum VolumeArchiveActions {
    static func export(session: HostSession, volume: VolumeEndpoint, name: String) {
        guard let folder = StorageFolderPanel.chooseFolder(prompt: String(localized: "Export Here")) else { return }
        LongOperationRunner.run(.storage, title: String(localized: "Export volume \(name)"), session: session) { op in
            op.update(progress: String(localized: "Writing the archive"))
            let file = try await session.exportVolume(volume, name: name, toFolder: folder.path)
            return String(localized: "Saved \(file).")
        }
    }

    static func importArchive(session: HostSession, into volume: VolumeEndpoint, name: String) {
        guard let file = StorageFolderPanel.chooseArchive() else { return }
        LongOperationRunner.run(.storage, title: String(localized: "Import into volume \(name)"), session: session) { op in
            op.update(progress: String(localized: "Reading the archive"))
            try await session.importVolume(file: file.path, into: volume)
            await session.refreshVolumeSizes()
            return String(localized: "Imported \(file.lastPathComponent).")
        }
    }
}

/// Image archives: save to and load from a tar file on any disk.
@MainActor
enum ImageArchiveActions {
    static func save(session: HostSession, reference: String) {
        guard let url = StorageFolderPanel.saveArchive(name: ImageArchive.archiveName(for: reference)) else { return }
        LongOperationRunner.run(.storage, title: String(localized: "Save image \(reference)"), session: session) { op in
            op.update(progress: String(localized: "Writing the archive"))
            try await session.saveImages([reference], to: url.path)
            return String(localized: "Saved \(url.path).")
        }
    }

    static func load(session: HostSession) {
        guard let url = StorageFolderPanel.chooseArchive() else { return }
        LongOperationRunner.run(.storage, title: String(localized: "Load images from \(url.lastPathComponent)"), session: session) { op in
            op.update(progress: String(localized: "Reading the archive"))
            try await session.loadImages(from: url.path)
            return String(localized: "Loaded \(url.lastPathComponent).")
        }
    }
}
