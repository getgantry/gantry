import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import DockerKit

/// The containers of one "Export as Compose" request.
struct ComposeExportTarget: Identifiable, Equatable {
    let containerIDs: [String]
    var id: String { containerIDs.joined(separator: ",") }
}

/// The "Export as Compose…" menu item. Several ids export one file.
struct ComposeExportMenuItem: View {
    let containerIDs: [String]
    @Binding var target: ComposeExportTarget?

    var body: some View {
        Button {
            target = ComposeExportTarget(containerIDs: containerIDs)
        } label: {
            Label("Export as Compose…", systemImage: "doc.text")
        }
        .disabled(containerIDs.isEmpty)
    }
}

extension View {
    /// Presents the export sheet while `target` is set.
    func composeExportSheet(_ target: Binding<ComposeExportTarget?>, session: HostSession) -> some View {
        sheet(item: target) { item in
            ComposeExportSheet(session: session, target: item)
        }
    }
}

/// Shows the Compose YAML of the selected containers, the masked secret
/// variables and the warnings, then copies or saves the file.
struct ComposeExportSheet: View {
    let session: HostSession
    let target: ComposeExportTarget

    @Environment(\.dismiss) private var dismiss
    @State private var sources: [ComposeExportSource] = []
    @State private var included: Set<ComposeExportSecret> = []
    @State private var result: ComposeExportResult?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ComposeExportHeader(count: target.containerIDs.count)
            content
            if let saveError { InlineErrorText(message: saveError) }
            footer
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 640)
        .task { await load() }
        .onChange(of: included) { regenerate() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Export Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            ComposeYAMLPreview(yaml: result.yaml)
            if !result.secrets.isEmpty {
                ComposeSecretToggles(secrets: result.secrets, included: $included)
            }
            ComposeWarningList(warnings: result.warnings)
        } else {
            ProgressView("Inspecting containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Copy") { copy() }
                .disabled(result == nil)
            Button("Save…") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil)
        }
    }

    private func load() async {
        do {
            sources = try await session.composeExportSources(for: target.containerIDs)
            regenerate()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func regenerate() {
        guard !sources.isEmpty else { return }
        do {
            result = try ComposeExporter.export(sources, options: ComposeExportOptions(includedSecrets: included))
            copied = false
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func copy() {
        guard let result else { return }
        copyToPasteboard(result.yaml)
        copied = true
    }

    private func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "docker-compose.yml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yml") ?? .yaml, .yaml]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ComposeExportWriter.write(result, to: url)
            saveError = nil
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct ComposeExportHeader: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export as Compose")
                .font(.title2.weight(.bold))
            Text(count == 1
                 ? String(localized: "A Compose file made from the settings of the container.")
                 : String(localized: "A Compose file with one service for each selected container."))
                .foregroundStyle(.secondary)
        }
    }
}

/// The YAML in a monospaced, selectable, scrolling view.
private struct ComposeYAMLPreview: View {
    let yaml: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: yaml)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityLabel(Text("Compose file"))
    }
}

/// One toggle for each masked variable.
private struct ComposeSecretToggles: View {
    let secrets: [ComposeExportSecret]
    @Binding var included: Set<ComposeExportSecret>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secret Values")
                .font(.headline)
            Text("These values look like secrets. The file reads them from the shell or from a .env file. Turn on a value to put it in the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(secrets) { secret in
                        Toggle(isOn: binding(for: secret)) {
                            Text(verbatim: "\(secret.service) · \(secret.variable)")
                                .font(.system(.callout, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        }
    }

    private func binding(for secret: ComposeExportSecret) -> Binding<Bool> {
        Binding {
            included.contains(secret)
        } set: { on in
            if on { included.insert(secret) } else { included.remove(secret) }
        }
    }
}

/// The settings that the file cannot express, or "No warnings".
private struct ComposeWarningList: View {
    let warnings: [ComposeExportWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Warnings")
                .font(.headline)
            if warnings.isEmpty {
                Label("No warnings", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(warnings) { ComposeWarningRow(warning: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
    }
}

private struct ComposeWarningRow: View {
    let warning: ComposeExportWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: warning.service)
                    .font(.callout.weight(.semibold))
                Text(verbatim: warning.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Warning, \(warning.service): \(warning.message)"))
    }
}
