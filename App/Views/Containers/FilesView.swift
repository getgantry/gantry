import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import DockerKit

/// File browser for a container's filesystem. Lists a directory, lets you
/// descend into folders, jump via an editable path bar, download a file (saved
/// as a raw tar) and upload a local file into the current directory (packed
/// into a single-entry ustar archive client-side).
struct FilesView: View {
    let session: HostSession
    let container: ContainerSummary

    @State private var path = "/"
    @State private var pathField = "/"
    @State private var entries: [ContainerFileEntry] = []
    @State private var selection: String?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var transferStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            content
        }
        .task(id: container.id) {
            path = "/"
            pathField = "/"
            await load()
        }
    }

    // MARK: - Path bar

    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            TextField("Path", text: $pathField)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { go(to: pathField) }
            Button("Go") { go(to: pathField) }
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            if session.host.capabilities.containerUpload {
                Button {
                    upload()
                } label: {
                    Label("Upload", systemImage: "square.and.arrow.up")
                }
                .help("Upload files or folders into this directory")
            }
        }
        .padding(8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            ContentUnavailableView(
                "Cannot Read Directory",
                systemImage: "folder.badge.questionmark",
                description: Text(errorText)
            )
        } else {
            List(selection: $selection) {
                if path != "/" {
                    ParentRow {
                        go(to: parentPath(of: path))
                    }
                }
                ForEach(entries, id: \.name) { entry in
                    FileRow(
                        entry: entry,
                        transfer: ContainerFileTransfer(
                            session: session,
                            containerID: container.id,
                            remotePath: join(path, entry.name),
                            name: entry.name,
                            isDirectory: entry.isDirectory
                        ),
                        fullPath: join(path, entry.name),
                        canTransfer: session.host.capabilities.containerFileTransfer,
                        onOpen: {
                            if entry.isDirectory {
                                go(to: join(path, entry.name))
                            }
                        },
                        onDownload: {
                            download(entry)
                        },
                        onDropURLs: entry.isDirectory && session.host.capabilities.containerUpload ? { urls in
                            Task { await uploadURLs(urls, into: join(path, entry.name)) }
                        } : nil
                    )
                    .tag(entry.name)
                }
            }
            // Return descends into the selected directory, like Finder's ⌘O.
            .onKeyPress(.return) {
                guard let selection,
                      let entry = entries.first(where: { $0.name == selection }),
                      entry.isDirectory else { return .ignored }
                go(to: join(path, entry.name))
                return .handled
            }
            // Dropping onto empty list area uploads into the current directory.
            .dropDestination(for: URL.self) { urls, _ in
                Task { await uploadURLs(urls, into: path) }
                return true
            }
            .overlay(alignment: .bottom) {
                if let transferStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(transferStatus).font(.caption)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - Navigation

    private func go(to newPath: String) {
        let normalized = newPath.isEmpty ? "/" : newPath
        path = normalized
        pathField = normalized
        Task { await load() }
    }

    private func parentPath(of p: String) -> String {
        let trimmed = p.hasSuffix("/") && p != "/" ? String(p.dropLast()) : p
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    private func join(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await session.listDirectory(containerID: container.id, path: path)
            entries = result.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            entries = []
            errorText = error.localizedDescription
        }
    }

    // MARK: - Download

    private func download(_ entry: ContainerFileEntry) {
        let panel = NSSavePanel()
        // The download endpoint returns a tar; hint that in the suggested name.
        panel.nameFieldStringValue = entry.name + ".tar"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let remotePath = join(path, entry.name)
        Task {
            transferStatus = "Downloading \(entry.name)…"
            defer { transferStatus = nil }
            do {
                let stream = try await session.downloadArchive(containerID: container.id, path: remotePath)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                for try await chunk in stream.bytes {
                    try handle.write(contentsOf: chunk)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Upload

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Folders are packed recursively (same path as a Finder folder drop),
        // so let the picker select them too.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        Task { await uploadURLs(urls, into: path) }
    }

    /// Packs each local URL (recursively for folders) and uploads it into
    /// `destination`. Shows an indeterminate progress overlay and refreshes the
    /// listing when the destination is the directory currently shown.
    private func uploadURLs(_ urls: [URL], into destination: String) async {
        guard !urls.isEmpty else { return }
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        transferStatus = "Uploading \(label)…"
        defer { transferStatus = nil }
        do {
            for url in urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let tar = try TarWriter.archiveFileURL(url, recursive: isDir.boolValue)
                try await session.uploadArchive(containerID: container.id, path: destination, tar: tar)
            }
            if destination == path {
                await load()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - File row

/// The ".." row navigating to the parent directory.
private struct ParentRow: View {
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.up.left")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("..")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
        .onTapGesture { onOpen() }
        .help("Go to the parent directory")
    }
}

private struct FileRow: View {
    let entry: ContainerFileEntry
    let transfer: ContainerFileTransfer
    let fullPath: String
    /// False when the host's engine has no archive endpoints (apple/container):
    /// the download/upload affordances are hidden.
    let canTransfer: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void
    /// Non-nil only for directory rows: handles a Finder drop into this folder.
    let onDropURLs: (([URL]) -> Void)?

    @State private var isDropTargeted = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if entry.isDirectory {
                // Affordance: directories open (double-click / Return).
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 1 : 0.45)
            } else {
                Text(Formatters.bytes(Int64(entry.size)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if canTransfer {
                    Button {
                        onDownload()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .opacity(hovered ? 1 : 0.55)
                    .help("Download")
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .modifier(DraggableTransferModifier(
            transfer: canTransfer ? transfer : nil,
            label: entry.name,
            icon: icon
        ))
        .contextMenu {
            if entry.isDirectory {
                Button("Open") { onOpen() }
            }
            if canTransfer {
                Button(entry.isDirectory ? "Download as \(entry.name).tar" : "Download…") { onDownload() }
            }
            Divider()
            Button("Copy Path") { copyToPasteboard(fullPath) }
        }
        .help(helpText)
        .modifier(DirectoryDropModifier(isTargeted: $isDropTargeted, onDropURLs: onDropURLs))
    }

    private var helpText: String {
        if entry.isDirectory {
            return canTransfer
                ? "Double-click to open · drag out to export"
                : "Double-click to open"
        }
        return canTransfer ? "Drag out to copy to Finder" : entry.name
    }

    private var backgroundColor: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.18) }
        if hovered { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var icon: String {
        if entry.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }
}

/// Makes the row draggable when the host's engine supports file transfer;
/// otherwise leaves the row untouched.
private struct DraggableTransferModifier: ViewModifier {
    let transfer: ContainerFileTransfer?
    let label: String
    let icon: String

    func body(content: Content) -> some View {
        if let transfer {
            content.draggable(transfer) {
                Label(label, systemImage: icon)
            }
        } else {
            content
        }
    }
}

/// Adds a Finder-URL drop target to directory rows (and is a no-op for files),
/// surfacing the targeted state for row highlighting.
private struct DirectoryDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onDropURLs: (([URL]) -> Void)?

    func body(content: Content) -> some View {
        if let onDropURLs {
            content.dropDestination(for: URL.self) { urls, _ in
                onDropURLs(urls)
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

// MARK: - Transferable for drag-out

/// Lets a container file/directory be dragged out to Finder. Files unpack the
/// single-entry tar to a correctly named temp file; directories are exported as
/// the raw `<name>.tar` archive (v1 — surfaced via the row tooltip).
struct ContainerFileTransfer: Transferable {
    let session: HostSession
    let containerID: String
    /// Absolute path of the item inside the container.
    let remotePath: String
    let name: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { transfer in
            let url = try await transfer.export()
            return SentTransferredFile(url)
        }
    }

    /// Downloads the item and writes it to a temp file, returning its URL.
    /// Files are unpacked from their single-entry tar; directories keep the tar.
    func export() async throws -> URL {
        let stream = try await session.downloadArchive(containerID: containerID, path: remotePath)
        var buffer = Data()
        for try await chunk in stream.bytes {
            buffer.append(chunk)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if isDirectory {
            let url = dir.appendingPathComponent(name + ".tar")
            try buffer.write(to: url)
            return url
        } else {
            let url = dir.appendingPathComponent(name)
            let contents = TarReader.firstFilePayload(in: buffer) ?? Data()
            try contents.write(to: url)
            return url
        }
    }

}
