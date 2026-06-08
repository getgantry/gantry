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

    private var trimmedImage: String { image.trimmingCharacters(in: .whitespaces) }
    private var canRun: Bool { !trimmedImage.isEmpty && !isWorking }

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
                    .onChange(of: image) { _, _ in suggestNameIfNeeded() }
                if !localImages.isEmpty {
                    Menu {
                        ForEach(localImages, id: \.self) { tag in
                            Button(tag) { image = tag; suggestNameIfNeeded(force: true) }
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("Pick a local image")
                }
            }
            TextField("Name (optional)", text: $name, prompt: Text("my-app"))
                .textFieldStyle(.roundedBorder)
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
        Section("Ports") {
            editorRows($ports, addLabel: "Add Port", empty: { PortRow() }) { $row in
                TextField("Host", text: $row.host, prompt: Text("8080")).frame(width: 80)
                Text(":").foregroundStyle(.secondary)
                TextField("Container", text: $row.container, prompt: Text("80")).frame(width: 80)
                Picker("", selection: $row.proto) {
                    Text("tcp").tag("tcp")
                    Text("udp").tag("udp")
                }
                .labelsHidden().frame(width: 70)
            }
        }
    }

    private var environmentSection: some View {
        Section("Environment") {
            editorRows($env, addLabel: "Add Variable", empty: { EnvRow() }) { $row in
                TextField("KEY", text: $row.key)
                Text("=").foregroundStyle(.secondary)
                TextField("VALUE", text: $row.value)
            }
        }
    }

    private var domainSection: some View {
        Section {
            if availableDomains.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text("No local domains. Add one in Settings → Apple to reach containers by name.")
                        .font(.callout).foregroundStyle(.secondary)
                }
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

    @ViewBuilder
    private func editorRows<Element: Identifiable, RowContent: View>(
        _ rows: Binding<[Element]>,
        addLabel: String,
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
    }

    private func suggestNameIfNeeded(force: Bool = false) {
        guard force || name.isEmpty else { return }
        // Derive a friendly default from the image's repository segment.
        let repo = trimmedImage
            .split(separator: "/").last.map(String.init) ?? trimmedImage
        let base = repo.split(separator: ":").first.map(String.init) ?? repo
        if !base.isEmpty { name = base }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
        if folderMountPath.isEmpty { folderMountPath = "/workspace" }
    }

    // MARK: - Run

    private func buildRequest() -> ContainerCreateRequest {
        let envList = env
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }

        let portMap = Dictionary(uniqueKeysWithValues:
            ports.filter { !$0.container.isEmpty && !$0.host.isEmpty }
                .map { ("\($0.container)/\($0.proto)", $0.host) }
        )

        var binds: [String] = []
        let trimmedFolder = folder.trimmingCharacters(in: .whitespaces)
        let mount = folderMountPath.trimmingCharacters(in: .whitespaces)
        if !trimmedFolder.isEmpty, !mount.isEmpty {
            binds.append("\(trimmedFolder):\(mount)")
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
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
            name: trimmedName.isEmpty ? nil : trimmedName
        )
    }

    private func run(pullFirst: Bool = false) async {
        errorText = nil
        imageMissing = false
        isWorking = true
        defer { isWorking = false; statusText = nil }
        do {
            if pullFirst {
                statusText = "Pulling \(trimmedImage)…"
                let stream = try await session.pullImage(reference: trimmedImage)
                for try await _ in stream {}
            }
            statusText = "Creating…"
            let id = try await session.createAndRun(buildRequest())
            if openInBrowser {
                await openWhenReady(containerID: id)
            }
            dismiss()
        } catch let DockerError.apiError(status, message) {
            errorText = message
            imageMissing = (status == 404)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Resolves the container's IP and opens its first port in the browser. The
    /// IP can take a beat to appear after start, so it polls briefly.
    private func openWhenReady(containerID: String) async {
        statusText = "Opening…"
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
