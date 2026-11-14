import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import AppCore

// Shared parts of Export Logs and Copy Visible Lines for the container and
// stack log views: the export item for `fileExporter`, the toolbar buttons,
// the display menu, and the menu-bar target.

/// What an export writes: the visible lines and their format, taken when the
/// save panel asks for the file.
struct LogExportSnapshot: Sendable {
    var lines: [LogExportLine]
    var format: LogExportFormat
}

/// The `fileExporter` item. The file is written to a temporary folder in
/// chunks by AppCore, then the save panel moves it to the destination, so a
/// large log never becomes one string in memory.
struct LogExportItem: Transferable {
    /// The default name without an extension.
    let fileName: String
    /// Reads the view's visible lines when the user clicks Save.
    let snapshot: @MainActor @Sendable () -> LogExportSnapshot

    static var transferRepresentation: some TransferRepresentation {
        // The save panel names its file wrapper from `suggestedFileName`.
        // Without it, NSFileWrapper raises on Save and the app stops.
        FileRepresentation(exportedContentType: .log) { item in
            try await item.file(extension: "log")
        }
        .suggestedFileName { $0.fileName + ".log" }
        FileRepresentation(exportedContentType: .plainText) { item in
            try await item.file(extension: "txt")
        }
        .suggestedFileName { $0.fileName + ".txt" }
    }

    private func file(extension ext: String) async throws -> SentTransferredFile {
        let snapshot = await snapshot()
        let name = fileName + "." + ext
        let url = try await Task.detached(priority: .userInitiated) {
            try LogExportWriter.writeTemporaryFile(snapshot.lines, format: snapshot.format, fileName: name)
        }.value
        return SentTransferredFile(url)
    }
}

extension View {
    /// The standard save panel for a log export. A failure goes to `error`;
    /// a cancel shows nothing.
    func logExporter(isPresented: Binding<Bool>, item: LogExportItem?, error: Binding<String?>) -> some View {
        fileExporter(
            isPresented: isPresented,
            item: item,
            contentTypes: [.log, .plainText],
            // With the extension, the panel saves `name.log` and swaps the
            // extension when the user picks Plain Text.
            defaultFilename: item.map { $0.fileName + ".log" },
            onCompletion: { result in
                guard case .failure(let failure) = result else { return }
                if (failure as? CocoaError)?.code == .userCancelled { return }
                error.wrappedValue = failure.localizedDescription
            },
            onCancellation: {}
        )
    }
}

/// Copy Visible Lines and Export Logs, side by side in a log view header.
struct LogExportButtons: View {
    let visibleCount: Int
    let copy: () -> Void
    let export: () -> Void

    var body: some View {
        Button(action: copy) {
            Image(systemName: "doc.on.doc")
        }
        .help("Copy Visible Lines")
        .accessibilityLabel("Copy Visible Lines")
        .disabled(visibleCount == 0)

        Button(action: export) {
            Image(systemName: "square.and.arrow.up")
        }
        .help("Export Logs…")
        .accessibilityLabel("Export Logs…")
        .disabled(visibleCount == 0)
    }
}

/// Show Timestamps and the time range. Hosts that report no log times
/// (Apple `container`) get a disabled menu and a help text that says why.
struct LogDisplayMenu: View {
    @Binding var showTimestamps: Bool
    @Binding var timeRange: LogTimeRange
    /// Whether any held line has a timestamp.
    let hasTimestamps: Bool

    private var isActive: Bool { showTimestamps || timeRange != .all }

    var body: some View {
        Menu {
            Toggle("Show Timestamps", isOn: $showTimestamps)
            Picker("Time Range", selection: $timeRange) {
                ForEach(LogTimeRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: isActive ? "clock.fill" : "clock")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!hasTimestamps)
        .help(hasTimestamps
              ? String(localized: "Timestamps and Time Range")
              : String(localized: "This host does not report log times."))
        .accessibilityLabel(String(localized: "Timestamps and Time Range"))
    }
}

enum LogTimeLabel {
    /// Local wall-clock time with milliseconds, for the timestamp column.
    static func text(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .secondFraction(.fractional(3)))
    }
}

/// The log view in front, for File > Export Logs… and Edit > Copy Visible
/// Log Lines.
struct LogExportTarget {
    var visibleCount: Int
    var export: () -> Void
    var copy: () -> Void
}

extension FocusedValues {
    @Entry var logExportTarget: LogExportTarget?
}

/// The menu-bar items of the log views.
struct LogCommands: Commands {
    @FocusedValue(\.logExportTarget) private var target

    private var isEnabled: Bool { (target?.visibleCount ?? 0) > 0 }

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Logs…") { target?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!isEnabled)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Visible Log Lines") { target?.copy() }
                .disabled(!isEnabled)
        }
    }
}
