import SwiftUI
import AppKit
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
                    FileRow(entry: entry) {
                        if entry.isDirectory {
                            go(to: join(path, entry.name))
                        }
                    } onDownload: {
                        download(entry)
                    }
                }
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

        Task {
            transferStatus = "Uploading \(url.lastPathComponent)…"
            defer { transferStatus = nil }
            do {
                let data = try Data(contentsOf: url)
                let tar = TarWriter.singleFile(name: url.lastPathComponent, contents: data)
                try await session.uploadArchive(containerID: container.id, path: path, tar: tar)
                await load()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - File row

private struct FileRow: View {
    let entry: ContainerFileEntry
    let onOpen: () -> Void
    let onDownload: () -> Void

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
        .onTapGesture(count: 2) { onOpen() }
    }

    private var icon: String {
        if entry.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }
}

// MARK: - Minimal tar writer

/// Builds a single-file ustar archive in memory — the inverse of the tar
/// parser used when reading archives. Sufficient for `PUT /containers/{id}/archive`.
enum TarWriter {
    static func singleFile(name: String, contents: Data) -> Data {
        var header = [UInt8](repeating: 0, count: 512)

        func write(_ string: String, at offset: Int, length: Int) {
            let bytes = Array(string.utf8.prefix(length))
            for (i, byte) in bytes.enumerated() { header[offset + i] = byte }
        }

        // Name (100), trimmed to fit.
        write(String(name.prefix(100)), at: 0, length: 100)
        // Mode, uid, gid as octal strings (NUL-terminated within their fields).
        write("000644 ", at: 100, length: 8)
        write("000000 ", at: 108, length: 8)
        write("000000 ", at: 116, length: 8)
        // Size: 11 octal digits + space.
        let octalSize = String(format: "%011o", contents.count)
        write(octalSize + " ", at: 124, length: 12)
        // Modification time.
        let octalTime = String(format: "%011o", Int(Date().timeIntervalSince1970))
        write(octalTime + " ", at: 136, length: 12)
        // Type flag '0' = regular file.
        header[156] = UInt8(ascii: "0")
        // ustar magic + version.
        write("ustar", at: 257, length: 6)
        header[263] = UInt8(ascii: "0")
        header[264] = UInt8(ascii: "0")

        // Checksum: spaces while computing, then octal value.
        for i in 148..<156 { header[i] = UInt8(ascii: " ") }
        let checksum = header.reduce(0) { $0 + Int($1) }
        write(String(format: "%06o", checksum), at: 148, length: 7)
        header[154] = 0
        header[155] = UInt8(ascii: " ")

        var archive = Data(header)
        archive.append(contents)

        // Pad file data to a 512-byte boundary.
        let remainder = contents.count % 512
        if remainder != 0 {
            archive.append(Data(repeating: 0, count: 512 - remainder))
        }
        // Two zero blocks mark end of archive.
        archive.append(Data(repeating: 0, count: 1024))
        return archive
    }
}
