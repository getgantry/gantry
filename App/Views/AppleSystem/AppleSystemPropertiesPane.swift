import SwiftUI
import AppKit
import AppCore

/// `container system property list` with editing. Since apple/container 1.0
/// the properties come from `~/.config/container/config.toml`: Gantry writes
/// the user's values there, and the services load them at their next start.
struct AppleSystemPropertiesPane: View {
    let session: HostSession

    @State private var properties: [AppleSystemProperty] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var editing: AppleSystemProperty?
    @State private var confirmRestart = false

    private var cli: String? { session.appleCLIOverride }
    private var pending: [AppleSystemProperty] { properties.filter(\.isPendingRestart) }

    private var sections: [(name: String, properties: [AppleSystemProperty])] {
        var order: [String] = []
        var grouped: [String: [AppleSystemProperty]] = [:]
        for property in properties {
            if grouped[property.section] == nil { order.append(property.section) }
            grouped[property.section, default: []].append(property)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppleSystemPaneHeader(pane: .properties, badge: nil) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Button {
                        revealConfigFile()
                    } label: {
                        Label(String(localized: "Show config.toml"), systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        Task { await reload() }
                    } label: {
                        Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                    }
                    .onSectionCommand(.refresh, .system) { Task { await reload() } }
                }
                .disabled(busy)
            }
            Divider()
            Form {
                if let errorText {
                    Section {
                        AppleSystemErrorBanner(message: errorText) { self.errorText = nil }
                    }
                }
                if !pending.isEmpty {
                    restartSection
                }
                ForEach(sections, id: \.name) { section in
                    Section {
                        ForEach(section.properties) { property in
                            row(property)
                        }
                    } header: {
                        Text(verbatim: section.name.isEmpty ? "—" : "[\(section.name)]")
                            .font(.system(.headline, design: .monospaced))
                    } footer: {
                        if let footer = Self.sectionFooter(section.name) {
                            Text(footer)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if loaded {
                    Section {
                        Text("Values in bold are set in your config.toml. The others are package defaults. Clear a value to go back to the default.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(AppleSystemPane.properties.title)
        .task { await reload() }
        .sheet(item: $editing) { property in
            AppleSystemPropertyEditor(property: property) {
                Task { await reload() }
            }
        }
        .confirmationDialog(
            String(localized: "Restart the apple/container services?"),
            isPresented: $confirmRestart
        ) {
            Button(String(localized: "Restart Services"), role: .destructive) { restart() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Running containers stop while the services restart.")
        }
    }

    private var restartSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.tint)
                Text(String(localized: "\(String(pending.count)) changed properties apply after the services restart."))
                    .font(.callout)
                Spacer()
                Button(String(localized: "Restart Services")) { confirmRestart = true }
                    .disabled(busy)
            }
        }
    }

    private func row(_ property: AppleSystemProperty) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: property.name)
                    .font(.system(.body, design: .monospaced))
                if let description = Self.description(for: property.key) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: (property.user ?? property.effective)?.display ?? String(localized: "not set"))
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(property.user != nil ? .semibold : .regular)
                    .foregroundStyle((property.user ?? property.effective) == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if property.isPendingRestart {
                    Text(String(localized: "Running: \(property.effective?.display ?? String(localized: "not set"))"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 320, alignment: .trailing)
            Button {
                editing = property
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .disabled(property.effective.map { if case .other = $0 { true } else { false } } ?? false)
            .help(String(localized: "Edit"))
        }
    }

    static func sectionFooter(_ section: String) -> String? {
        switch section {
        case "build": String(localized: "The image builder container. Changes apply when the builder is next created.")
        case "container": String(localized: "Defaults for containers created without CPU or memory options.")
        case "dns": String(localized: "Container host names resolve under this domain. Create the domain in Settings first.")
        case "kernel": String(localized: "The kernel that “Install Recommended Kernel” downloads.")
        case "network": String(localized: "Default subnets for new networks.")
        case "registry": String(localized: "The registry for image names without a host.")
        case "vminit": String(localized: "The init image that boots container VMs.")
        case "machine": String(localized: "Defaults for new machines.")
        default: nil
        }
    }

    static func description(for key: String) -> String? {
        switch key {
        case "build.cpus", "container.cpus", "machine.cpus": String(localized: "Number of CPUs")
        case "build.memory", "container.memory", "machine.memory": String(localized: "Memory, for example 2048mb or 4g")
        case "build.rosetta": String(localized: "Use Rosetta to build amd64 images")
        case "build.image": String(localized: "Builder image reference")
        case "dns.domain": String(localized: "Local DNS domain for container names")
        case "kernel.binaryPath": String(localized: "Kernel file inside the archive")
        case "kernel.url": String(localized: "Kernel archive URL")
        case "kernel.digest": String(localized: "Expected archive digest (sha256:…)")
        case "network.subnet": String(localized: "IPv4 subnet, for example 192.168.100.0/24")
        case "network.subnetv6": String(localized: "IPv6 subnet, for example fd00:abcd::/64")
        case "registry.domain": String(localized: "Default registry host")
        case "vminit.image": String(localized: "vminit image reference")
        case "machine.homeMount": String(localized: "Home folder mount: rw, ro or none")
        case "machine.virtualization": String(localized: "Nested virtualization")
        default: nil
        }
    }

    private func revealConfigFile() {
        let url = AppleContainerControl.userConfigFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().deletingLastPathComponent().path)
        }
    }

    private func restart() {
        Task {
            busy = true
            errorText = nil
            defer { busy = false }
            do {
                try await AppleContainerControl.restartServices(cliOverride: cli)
            } catch {
                errorText = error.localizedDescription
            }
            await reload()
        }
    }

    private func reload() async {
        do {
            properties = try await AppleContainerControl.listProperties(cliOverride: cli)
        } catch {
            errorText = error.localizedDescription
        }
        loaded = true
    }
}

/// Edits one property with an editor that fits its type and validates the
/// value before it is written.
struct AppleSystemPropertyEditor: View {
    let property: AppleSystemProperty
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorText: String?

    private var validation: Result<AppleSystemPropertyValue, Error> {
        Result { try AppleContainerControl.validatedPropertyValue(text, kind: property.kind) }
    }

    private var validationMessage: String? {
        guard !text.isEmpty, case .failure(let error) = validation else { return nil }
        return error.localizedDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if let choices = property.kind.choices {
                        Picker(String(localized: "Value"), selection: $text) {
                            ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        TextField(String(localized: "Value"), text: $text, prompt: Text(verbatim: property.effective?.display ?? ""))
                            .font(.system(.body, design: .monospaced))
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    LabeledContent(String(localized: "Running value")) {
                        Text(verbatim: property.effective?.display ?? String(localized: "not set"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(verbatim: property.key)
                        .font(.system(.headline, design: .monospaced))
                } footer: {
                    Text("Gantry writes the value to ~/.config/container/config.toml. Restart the services to apply it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if property.user != nil {
                    Button(String(localized: "Use Default"), role: .destructive) { clear() }
                        .help(String(localized: "Remove the value from config.toml"))
                }
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((try? validation.get()) == nil)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear { text = (property.user ?? property.effective)?.display ?? "" }
    }

    private func save() {
        do {
            try AppleContainerControl.setUserProperty(property.key, to: text)
            onChange()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clear() {
        do {
            try AppleContainerControl.clearUserProperty(property.key)
            onChange()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
