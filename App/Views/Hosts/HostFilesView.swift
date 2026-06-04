import SwiftUI
import AppKit
import AppCore
import SSHKit

/// SFTP file browser for the SSH host itself: list directories, descend,
/// download files. Mirrors the container Files tab interactions.
struct HostFilesView: View {
    @Bindable var session: HostSession

    @State private var path = "/"
    @State private var pathField = "/"
    @State private var entries: [HostFileEntry] = []
    @State private var selection: String?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var transferStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
        }
        .navigationTitle("Host Files")
        .task(id: session.id) {
            path = "/"
            pathField = "/"
            await load()
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
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
        }
        .padding(8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !session.supportsHostAccess {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "folder.badge.questionmark",
                description: Text("Host file browsing needs a connected SSH host.")
            )
        } else if isLoading && entries.isEmpty {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText, entries.isEmpty {
            ContentUnavailableView(
                "Cannot Read Directory",
                systemImage: "folder.badge.questionmark",
                description: Text(errorText)
            )
        } else {
            List(selection: $selection) {
                if path != "/" {
                    HostParentRow {
                        go(to: parentPath(of: path))
                    }
                }
                ForEach(entries) { entry in
                    HostFileRow(
                        entry: entry,
                        onOpen: {
                            if entry.isDirectory || entry.isSymlink {
                                go(to: join(path, entry.name))
                            }
                        },
                        onDownload: entry.isDirectory ? nil : { download(entry) },
                        onCopyPath: { copyToPasteboard(join(path, entry.name)) }
                    )
                    .tag(entry.name)
                }
            }
            .onKeyPress(.return) {
                guard let selection,
                      let entry = entries.first(where: { $0.name == selection }),
                      entry.isDirectory || entry.isSymlink else { return .ignored }
                go(to: join(path, entry.name))
                return .handled
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
        guard session.supportsHostAccess else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let fs = try session.hostFileSystem()
            entries = try await fs.listDirectory(path)
        } catch {
            entries = []
            errorText = error.localizedDescription
        }
    }

    // MARK: - Download

    private func download(_ entry: HostFileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let remotePath = join(path, entry.name)
        Task {
            transferStatus = "Downloading \(entry.name)…"
            defer { transferStatus = nil }
            do {
                let fs = try session.hostFileSystem()
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                do {
                    try await fs.downloadFile(remotePath) { chunk in
                        try handle.write(contentsOf: chunk)
                    }
                    try? handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Rows

private struct HostParentRow: View {
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

private struct HostFileRow: View {
    let entry: HostFileEntry
    let onOpen: () -> Void
    /// Nil for directories (downloads are file-only over SFTP for now).
    let onDownload: (() -> Void)?
    let onCopyPath: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if entry.isDirectory || entry.isSymlink {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovered ? 1 : 0.45)
            } else {
                Text(Formatters.bytes(entry.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let onDownload {
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
        .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .contextMenu {
            if entry.isDirectory || entry.isSymlink {
                Button("Open") { onOpen() }
            }
            if let onDownload {
                Button("Download…") { onDownload() }
            }
            Divider()
            Button("Copy Path") { onCopyPath() }
        }
        .help(entry.isDirectory ? "Double-click to open" : "")
    }

    private var icon: String {
        if entry.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if entry.isDirectory { return "folder.fill" }
        return "doc"
    }
}
