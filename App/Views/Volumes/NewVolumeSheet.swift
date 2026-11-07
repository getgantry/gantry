import SwiftUI
import AppKit
import AppCore
import DockerKit

/// Where a new volume keeps its data.
enum NewVolumeLocation: String, CaseIterable, Identifiable {
    case engine
    case folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .engine: String(localized: "Managed by the Engine")
        case .folder: String(localized: "Folder on a Disk")
        }
    }
}

/// Sheet to create a new volume: a named volume of the engine, or a folder
/// on a disk (on this Mac only).
struct NewVolumeSheet: View {
    let session: HostSession

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "local"
    @State private var location: NewVolumeLocation = .engine
    @State private var parent = ""
    @State private var folderCheck: StorageCheck?
    @State private var labels: [LabelPair] = []
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Volume").font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                if session.usesLocalPaths { locationPicker }
                if location == .engine {
                    TextField("Driver", text: $driver).textFieldStyle(.roundedBorder)
                } else {
                    FolderLocationField(parent: $parent, check: $folderCheck, name: name)
                }
                LabelEditor(pairs: $labels)
            }
            .disabled(working)
            if let errorText { InlineErrorText(message: errorText) }
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    private var locationPicker: some View {
        Picker(String(localized: "Location"), selection: $location) {
            ForEach(NewVolumeLocation.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var canCreate: Bool {
        guard !trimmedName.isEmpty, !working else { return false }
        guard location == .folder else { return true }
        return !parent.isEmpty && folderCheck?.isAllowed == true
    }

    private func submit() {
        working = true
        let nameValue = trimmedName
        let labelDict = labels.asDictionary
        Task {
            errorText = await create(name: nameValue, labels: labelDict)
            working = false
            if errorText == nil { dismiss() }
        }
    }

    private func create(name: String, labels: [String: String]) async -> String? {
        switch location {
        case .engine:
            let driverValue = driver.trimmingCharacters(in: .whitespaces)
            return await session.attempt(fallback: String(localized: "Could not create the volume.")) {
                await session.createVolume(
                    name: name, driver: driverValue.isEmpty ? "local" : driverValue, labels: labels
                ) != nil
            }
        case .folder:
            do {
                try await session.createFolderVolume(name: name, parent: parent, labels: labels)
                await session.refreshVolumes()
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The parent folder of a folder volume, with the disk check.
struct FolderLocationField: View {
    @Binding var parent: String
    /// The check of `parent`; nil while it runs.
    @Binding var check: StorageCheck?
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(String(localized: "Folder"), text: $parent)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Choose…")) { choose() }
            }
            if !parent.isEmpty {
                Text("Gantry makes the folder \(FolderVolumeRules.folder(named: name.isEmpty ? "…" : name, in: parent)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let check { StorageIssueList(check: check) } else { ProgressView().controlSize(.small) }
            }
        }
        .task(id: parent) {
            check = nil
            guard !parent.isEmpty else { return }
            check = await StorageCheckLoader.folderVolume(path: parent)
        }
    }

    private func choose() {
        if let url = StorageFolderPanel.chooseFolder(prompt: String(localized: "Choose"), start: parent) {
            parent = url.path
        }
    }
}

/// The warnings and refusals of a disk check, one per line.
struct StorageIssueList: View {
    let check: StorageCheck

    var body: some View {
        ForEach(check.issues, id: \.self) { issue in
            Label(issue.message, systemImage: issue.isBlocking ? "xmark.octagon" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(issue.isBlocking ? .red : .orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Open and save panels that start on a disk.
@MainActor
enum StorageFolderPanel {
    static func chooseFolder(prompt: String, start: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let start, !start.isEmpty { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseArchive() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveArchive(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
