import SwiftUI
import AppKit
import AppCore
import DockerKit

/// OrbStack-style quick launch tuned for apple/container: pick a local image,
/// name it, optionally share a macOS folder and map ports, choose a local DNS
/// domain, then run — and the container's address opens straight in the browser.
/// Less surface than the full create sheet, optimized for the common path.
struct QuickRunSheet: View {
    @Bindable var session: HostSession
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var folder = ""
    @State private var folderMountPath = "/workspace"
    @State private var ports: [PortRow] = [PortRow()]
    @State private var env: [EnvRow] = []
    @State private var domain = ""           // "" = no domain
    @State private var availableDomains: [String] = []
    @State private var openInBrowser = true

    @State private var isWorking = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var imageMissing = false
    /// True once the user typed a name; until then it follows the image.
    @State private var nameEdited = false
    /// Set when the runtime refused the name; shown under the Name field.
    @State private var nameError: String?
    /// Set when the new container stopped right after it started.
    @State private var earlyExit: StartedContainerExit?

    private var trimmedImage: String { image.trimmingCharacters(in: .whitespaces) }

    private var portEntries: [ContainerForm.PortEntry] {
        ports.map { ContainerForm.PortEntry(host: $0.host, container: $0.container, proto: $0.proto) }
    }

    /// Port problems keyed by row id. Quick Run drops rows without a host port.
    private var portIssues: [UUID: ContainerForm.PortIssue] {
        let byIndex = ContainerForm.portIssues(portEntries, requireHost: true)
        return Dictionary(byIndex.map { (ports[$0.key].id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private var nameIssue: String? {
        ContainerForm.nameIssue(name, taken: ContainerForm.takenNames(session.containers))
    }

    private var canRun: Bool {
        !trimmedImage.isEmpty && !isWorking && portIssues.isEmpty && nameIssue == nil
    }

    /// The Name field: typing marks the name as the user's own, and clearing
    /// it hands it back to the image-derived suggestion.
    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { newValue in
                name = newValue
                nameEdited = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
                nameError = nil
                if !nameEdited { suggestName() }
            }
        )
    }

    private var cliOverride: String? { session.host.socketPathOverride }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                imageSection
                folderSection
                portsSection
                environmentSection
                domainSection
                runtimeFeedback
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .startedContainerExitAlert($earlyExit, session: session) { dismiss() }
        .task {
            await loadDomains()
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").foregroundStyle(.tint)
            Text("Quick Run").font(.title2.weight(.semibold))
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if let statusText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await run() }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
        .padding()
    }

    // MARK: - Sections

    private var imageSection: some View {
        Section("Image") {
            HStack(spacing: 6) {
                TextField("Image", text: $image, prompt: Text("nginx:alpine"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: image) { _, _ in suggestName() }
                if !localImages.isEmpty {
                    Menu {
                        ForEach(localImages, id: \.self) { tag in
                            Button(tag) { image = tag }
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Pick a local image")
                    .accessibilityLabel("Pick a local image")
                }
            }
            TextField("Name (optional)", text: nameBinding, prompt: Text("my-app"))
                .textFieldStyle(.roundedBorder)
            FieldError(message: nameIssue ?? nameError)
        }
    }

    private var folderSection: some View {
        Section {
            HStack(spacing: 6) {
                TextField("Folder on your Mac", text: $folder, prompt: Text("Not shared"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    pickFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Choose a folder to share into the container")
                .accessibilityLabel("Choose a folder to share into the container")
            }
            if !folder.isEmpty {
                HStack(spacing: 6) {
                    Text("Mounted at").foregroundStyle(.secondary).font(.callout)
                    TextField("Container path", text: $folderMountPath, prompt: Text("/workspace"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
            }
        } header: {
            Text("Share a Folder")
        } footer: {
            Text("Bind-mount a macOS folder into the container at create time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var portsSection: some View {
        Section {
            editorRows($ports, addLabel: "Add Port", empty: { PortRow() }) { $row in
                portField("Host", text: $row.host, prompt: "8080")
                Text(verbatim: ":").foregroundStyle(.secondary)
                portField("Container", text: $row.container, prompt: "80")
                Picker("Protocol", selection: $row.proto) {
                    Text(verbatim: "tcp").tag("tcp")
                    Text(verbatim: "udp").tag("udp")
                }
                .labelsHidden().frame(width: 70)
                PortIssueIcon(issue: portIssues[row.id])
            }
        } header: {
            Text("Ports")
        } footer: {
            FieldError(message: portIssues.values.first?.message)
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            editorRows($env, addLabel: "Add Variable", empty: { EnvRow() }) { $row in
                TextField("KEY", text: $row.key)
                Text(verbatim: "=").foregroundStyle(.secondary)
                TextField("VALUE", text: $row.value)
            }
        }
    }

    private var domainSection: some View {
        Section {
            if availableDomains.isEmpty {
                NoLocalDomainsRow()
            } else {
                Picker("DNS domain", selection: $domain) {
                    Text("None").tag("")
                    ForEach(availableDomains, id: \.self) { d in Text(d).tag(d) }
                }
                if !domain.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Reachable as \(name.trimmingCharacters(in: .whitespaces)).\(domain)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Toggle("Open in browser when ready", isOn: $openInBrowser)
        } header: {
            Text("Networking")
        }
    }

    @ViewBuilder
    private var runtimeFeedback: some View {
        if let errorText {
            Section {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                if imageMissing {
                    Button {
                        Task { await run(pullFirst: true) }
                    } label: {
                        Label("Pull image and run", systemImage: "arrow.down.circle")
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    // MARK: - Reusable editor list

    /// A port field with its label outside the fixed field width, so a long
    /// label in another language does not wrap.
    private func portField(_ label: LocalizedStringKey, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 6) {
            Text(label).fixedSize()
            TextField(label, text: text, prompt: Text(verbatim: prompt))
                .labelsHidden()
                .frame(width: 80)
        }
    }

    @ViewBuilder
    private func editorRows<Element: Identifiable, RowContent: View>(
        _ rows: Binding<[Element]>,
        addLabel: LocalizedStringKey,
        empty: @escaping () -> Element,
        @ViewBuilder content: @escaping (Binding<Element>) -> RowContent
    ) -> some View {
        ForEach(rows) { $row in
            HStack(spacing: 6) {
                content($row)
                Spacer(minLength: 0)
                Button {
                    rows.wrappedValue.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove row")
                .accessibilityLabel("Remove row")
            }
        }
        Button {
            rows.wrappedValue.append(empty())
        } label: {
            Label(addLabel, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Data

    private var localImages: [String] {
        session.images
            .flatMap { $0.repoTags }
            .filter { $0 != "<none>:<none>" && !$0.hasPrefix("<none>") }
            .sorted()
    }

    private func loadDomains() async {
        availableDomains = (try? await AppleContainerControl.listDomains(cliOverride: cliOverride)) ?? []
        // Assign a DNS domain by default so the container is reachable by name.
        if domain.isEmpty {
            domain = DefaultDNSDomain.preferred(in: availableDomains)
        }
    }

    /// Follows the image with a free name (`nginx`, then `nginx-2`, …) until
    /// the user types a name of their own.
    private func suggestName() {
        guard !nameEdited else { return }
        let base = ContainerForm.baseName(forImage: trimmedImage)
        name = base.isEmpty ? "" : session.uniqueContainerName(base: base)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Share")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        if folderMountPath.isEmpty { folderMountPath = "/workspace" }
    }

    // MARK: - Run

    private func buildRequest() -> ContainerCreateRequest {
        let envList = env
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }

        let portMap = ContainerForm.portMap(portEntries, requireHost: true)

        var binds: [String] = []
        let trimmedFolder = folder.trimmingCharacters(in: .whitespaces)
        let mount = folderMountPath.trimmingCharacters(in: .whitespaces)
        if !trimmedFolder.isEmpty, !mount.isEmpty {
            binds.append("\(trimmedFolder):\(mount)")
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Always give the container a friendly, unique name so its DNS hostname
        // (name.domain) is meaningful even when the user left the field blank.
        let resolvedName = trimmedName.isEmpty
            ? session.uniqueContainerName(forImage: trimmedImage)
            : trimmedName
        let trimmedDomain = domain.trimmingCharacters(in: .whitespaces)
        // Record the domain as a label so the container's address view can show
        // the resolvable hostname reliably later.
        let labels = trimmedDomain.isEmpty ? [:] : [AppleAddressSection.domainLabelKey: trimmedDomain]

        return ContainerCreateRequest(
            image: trimmedImage,
            env: envList,
            ports: portMap,
            binds: binds,
            tty: false,
            labels: labels,
            domainname: trimmedDomain.isEmpty ? nil : trimmedDomain,
            name: resolvedName
        )
    }

    private func run(pullFirst: Bool = false) async {
        errorText = nil
        nameError = nil
        imageMissing = false
        isWorking = true
        defer { isWorking = false; statusText = nil }
        do {
            if pullFirst {
                statusText = String(localized: "Pulling \(trimmedImage)…")
                let stream = try await session.pullImage(reference: trimmedImage)
                for try await _ in stream {}
            }
            statusText = String(localized: "Creating…")
            let request = buildRequest()
            let id = try await session.createAndRun(request)
            statusText = String(localized: "Starting…")
            if let exit = await session.earlyExit(containerID: id) {
                earlyExit = StartedContainerExit(
                    hostID: session.host.id,
                    containerID: id,
                    name: request.name ?? String(id.prefix(12)),
                    exitCode: exit.exitCode
                )
                return
            }
            if openInBrowser {
                await openWhenReady(containerID: id)
            }
            dismiss()
        } catch {
            show(error)
        }
    }

    /// Routes a run failure to the right inline place: a name conflict goes
    /// under the Name field instead of the raw daemon text.
    private func show(_ error: Error) {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, ContainerForm.isNameConflict(error) {
            nameError = ContainerForm.nameInUseMessage(typed)
        } else if case let DockerError.apiError(status, message) = error {
            errorText = message
            imageMissing = (status == 404)
        } else {
            errorText = error.localizedDescription
        }
    }

    /// Resolves the container's IP and opens its first port in the browser. The
    /// IP can take a beat to appear after start, so it polls briefly.
    private func openWhenReady(containerID: String) async {
        statusText = String(localized: "Opening…")
        let targetPort = ports.compactMap { Int($0.container) }.first
        for _ in 0..<10 {
            if let details = await session.details(for: containerID),
               let ip = details.networkSettings.ipAddress, !ip.isEmpty {
                let port = targetPort ?? firstPort(in: details)
                if let port, let url = URL(string: "http://\(ip):\(port)") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func firstPort(in details: ContainerDetails) -> Int? {
        details.networkSettings.ports?.keys
            .compactMap { Int($0.split(separator: "/").first.map(String.init) ?? "") }
            .min()
    }
}

// MARK: - Editor row models

private struct PortRow: Identifiable {
    let id = UUID()
    var host = ""
    var container = ""
    var proto = "tcp"
}

private struct EnvRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}
