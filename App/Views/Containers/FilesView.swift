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
            Button {
                upload()
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .help("Upload a file into this directory")
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
            List {
                if path != "/" {
                    Button {
                        go(to: parentPath(of: path))
                    } label: {
                        Label("..", systemImage: "arrow.turn.up.left")
                    }
                    .buttonStyle(.plain)
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
                        onOpen: {
                            if entry.isDirectory {
                                go(to: join(path, entry.name))
                            }
                        },
                        onDownload: {
                            download(entry)
                        },
                        onDropURLs: entry.isDirectory ? { urls in
                            Task { await uploadURLs(urls, into: join(path, entry.name)) }
                        } : nil
                    )
                }
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
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await uploadURLs([url], into: path) }
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

private struct FileRow: View {
    let entry: ContainerFileEntry
    let transfer: ContainerFileTransfer
    let onOpen: () -> Void
    let onDownload: () -> Void
    /// Non-nil only for directory rows: handles a Finder drop into this folder.
    let onDropURLs: (([URL]) -> Void)?

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if !entry.isDirectory {
                Text(Formatters.bytes(Int64(entry.size)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    onDownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onTapGesture(count: 2) { onOpen() }
        .draggable(transfer) {
            Label(entry.name, systemImage: icon)
        }
        .help(entry.isDirectory
              ? "Drag out to save as \(entry.name).tar"
              : "Drag out to copy to Finder")
        .modifier(DirectoryDropModifier(isTargeted: $isDropTargeted, onDropURLs: onDropURLs))
    }

    private var icon: String {
        if entry.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
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
            let contents = Self.singleFilePayload(fromArchive: buffer) ?? Data()
            try contents.write(to: url)
            return url
        }
    }

    /// Extracts the first regular-file payload from a tar archive.
    private static func singleFilePayload(fromArchive data: Data) -> Data? {
        let bytes = [UInt8](data)
        let block = 512
        var offset = 0
        while offset + block <= bytes.count {
            let header = Array(bytes[offset ..< offset + block])
            offset += block
            if header.allSatisfy({ $0 == 0 }) { break }

            // size field (octal, 12 bytes at 124).
            var size = 0
            for i in 124..<136 {
                let b = header[i]
                if b == 0 || b == UInt8(ascii: " ") {
                    if size != 0 { break } else { continue }
                }
                guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "7") else { break }
                size = size * 8 + Int(b - UInt8(ascii: "0"))
            }
            let padded = ((size + block - 1) / block) * block
            let typeFlag = header[156]

            // Skip GNU/PAX long-name extension headers; the next header is the file.
            if typeFlag == UInt8(ascii: "L") || typeFlag == UInt8(ascii: "x") || typeFlag == UInt8(ascii: "g") {
                offset += padded
                continue
            }

            if typeFlag == UInt8(ascii: "0") || typeFlag == 0 {
                let end = min(offset + size, bytes.count)
                guard offset <= end else { return nil }
                return data.subdata(in: offset ..< end)
            }
            offset += padded
        }
        return nil
    }
}
