import SwiftUI
import AppCore
import DockerKit
import SSHKit

/// SSH auth method selection, shared by the add- and edit-host forms.
enum AuthChoice: Hashable {
    case automatic
    case keyFile
    case password
}

/// Which engine the new host runs: Docker over SSH, or the local
/// apple/container services.
private enum HostTypeChoice: Hashable {
    case ssh
    case appleContainer
    case localDocker
}

/// Sheet for adding a new host: an SSH Docker host (resolving ssh_config live
/// to show the values that will apply) or a local apple/container host.
/// "Test Connection" dials the host with the real connect path first.
struct AddHostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// One id for the test and the added host, so a passphrase stored in the
    /// Keychain during the test belongs to the host that is added.
    @State private var hostID = UUID()
    @State private var hostType: HostTypeChoice = .ssh
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var authChoice: AuthChoice = .automatic
    @State private var keyFilePath = ""
    @State private var password = ""

    @State private var showingKeyImporter = false
    @State private var summary: SSHConnectionSummary?
    @State private var resolveTask: Task<Void, Never>?
    @State private var connectionTest = ConnectionTest()

    /// Concrete host aliases from ~/.ssh/config for one-click import.
    private let configHosts = SSHConfig.listHosts()
    @State private var selectedConfigHost: String?

    /// SSH-based Docker contexts (`docker context ls`) for one-click import.
    private let dockerContexts: [DockerContextStore.Entry] = DockerContextStore.list().filter {
        if case .ssh = DockerContextStore.endpoint(for: $0.host) { return true }
        return false
    }
    @State private var selectedContext: String?

    /// Where the apple/container CLI was found, if anywhere.
    private let appleCLIPath = AppleContainerCLIDiscovery.discover()

    /// The Docker socket found at the usual places, if any.
    private let dockerSocketPath = DockerSocketDiscovery.discover()
    /// A custom socket path for Local Docker; empty means "find it".
    @State private var socketPath = ""

    private var defaultUser: String { NSUserName() }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var portInput: PortInput { PortInput(port) }
    private var hostMessage: String? { SSHHostInput.message(for: host) }

    private var canAdd: Bool {
        switch hostType {
        case .ssh: !trimmedHost.isEmpty && hostMessage == nil && portInput != .invalid
        case .appleContainer, .localDocker: true
        }
    }

    /// Every field that changes the host; a change voids the last test.
    private var formSignature: [String] {
        [String(describing: hostType), host, port, user, String(describing: authChoice), keyFilePath, password, socketPath]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            typePicker
            form
            ConnectionTestStatus(test: connectionTest, engineName: engineName)
            footer
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(
            isPresented: $showingKeyImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                keyFilePath = url.path
            }
        }
        .onChange(of: formSignature) {
            connectionTest.reset()
            scheduleResolve()
        }
        .modifier(ConnectionTestPrompts(test: connectionTest, password: authChoice == .password ? password : ""))
        .onDisappear {
            resolveTask?.cancel()
            connectionTest.reset()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: headerSymbol)
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Add Host")
                .font(.title2.weight(.semibold))
        }
    }

    private var typePicker: some View {
        Picker("Type", selection: $hostType) {
            Text("SSH Docker Host").tag(HostTypeChoice.ssh)
            Text("Apple Container").tag(HostTypeChoice.appleContainer)
            Text("Local Docker").tag(HostTypeChoice.localDocker)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var form: some View {
        switch hostType {
        case .ssh:
            sshForm
        case .appleContainer:
            appleContainerForm
        case .localDocker:
            localDockerForm
        }
    }

    private var footer: some View {
        HStack {
            Button("Test Connection") { testConnection() }
                .disabled(!canAdd || connectionTest.isTesting)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
        }
    }

    private var headerSymbol: String {
        switch hostType {
        case .ssh: "network"
        case .appleContainer: "apple.logo"
        case .localDocker: "shippingbox"
        }
    }

    private var engineName: String {
        hostType == .appleContainer ? String(localized: "container CLI") : "Docker"
    }

    // MARK: - Local Docker form

    private var localDockerForm: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name, prompt: Text(verbatim: LocalDockerPolicy.defaultName))
                TextField("Socket path (optional)", text: $socketPath, prompt: Text("Find automatically"))
            } footer: {
                localDockerFooter
            }
        }
        .formStyle(.grouped)
    }

    private var localDockerFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The Docker engine on this Mac: Docker Desktop, OrbStack, Colima, Rancher Desktop or Podman.")
            if let dockerSocketPath {
                Label("Socket found at \(dockerSocketPath)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("No Docker socket found yet. The host shows as not installed until one appears.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    // MARK: - Apple Container form

    private var appleContainerForm: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name, prompt: Text("Apple Container"))
            } footer: {
                appleContainerFooter
            }
        }
        .formStyle(.grouped)
    }

    private var appleContainerFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manages Linux containers run by apple/container on this Mac, driven through the `container` CLI. Lifecycle, logs, terminal, stats, images, volumes and networks are supported.")
            if let appleCLIPath {
                Label("CLI found at \(appleCLIPath)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label(
                    "The `container` CLI was not found.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Button("Install apple/container…") {
                    // Close this sheet first so the setup sheet can take
                    // its place (one sheet per presenter at a time).
                    dismiss()
                    NotificationCenter.default.post(name: .gantryShowContainerSetup, object: nil)
                }
                .controlSize(.small)
            }
        }
        .font(.footnote)
    }

    // MARK: - SSH form

    private var sshForm: some View {
        Form {
            importSections
            connectionSection
            authenticationSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var importSections: some View {
        if !configHosts.isEmpty {
            Section {
                Picker("Import from SSH config", selection: $selectedConfigHost) {
                    Text("Choose a host…").tag(String?.none)
                    ForEach(configHosts, id: \.self) { alias in
                        Text(alias).tag(String?.some(alias))
                    }
                }
                .onChange(of: selectedConfigHost) { _, alias in
                    if let alias { applyConfigHost(alias) }
                }
            } footer: {
                Text("Hosts from ~/.ssh/config. Picking one fills the fields below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if !dockerContexts.isEmpty {
            Section {
                Picker("Import from Docker context", selection: $selectedContext) {
                    Text("Choose a context…").tag(String?.none)
                    ForEach(dockerContexts, id: \.name) { entry in
                        Text(entry.name).tag(String?.some(entry.name))
                    }
                }
                .onChange(of: selectedContext) { _, contextName in
                    if let contextName { applyDockerContext(contextName) }
                }
            } footer: {
                Text("SSH contexts from docker context ls. Picking one fills the fields below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("Name (optional)", text: $name, prompt: Text("Same as the host"))
            TextField("Host", text: $host, prompt: Text("Host name, IP address or ssh_config alias"))
            if let hostMessage { inlineError(hostMessage) }
            TextField("Port (optional)", text: $port, prompt: Text("From ssh_config, else 22"))
            if let message = portInput.message { inlineError(message) }
            TextField("User (optional)", text: $user, prompt: Text("From ssh_config, else \(defaultUser)"))
        } footer: {
            if let summary { SSHSummaryView(summary: summary, authChoice: authChoice) }
        }
    }

    private var authenticationSection: some View {
        Section("Authentication") {
            Picker("Method", selection: $authChoice) {
                Text("SSH config & default keys").tag(AuthChoice.automatic)
                Text("Private key file").tag(AuthChoice.keyFile)
                Text("Password").tag(AuthChoice.password)
            }

            switch authChoice {
            case .automatic:
                Text("Gantry resolves keys from your SSH config and the usual default identities.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .keyFile:
                HStack {
                    Text(keyFilePath.isEmpty ? "No key selected" : keyFilePath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(keyFilePath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { showingKeyImporter = true }
                }
            case .password:
                SecureField("Password", text: $password)
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    // MARK: - Actions

    /// The host that the form describes, with the form's stable id.
    private func makeHost() -> DockerHost {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch hostType {
        case .localDocker:
            let path = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return DockerHost(
                id: hostID,
                name: displayName.isEmpty ? LocalDockerPolicy.defaultName : displayName,
                kind: .local,
                socketPathOverride: path.isEmpty ? nil : path
            )
        case .appleContainer:
            return DockerHost(
                id: hostID,
                name: displayName.isEmpty ? "Apple Container" : displayName,
                kind: .appleContainer
            )
        case .ssh:
            return DockerHost(
                id: hostID,
                name: displayName.isEmpty ? trimmedHost : displayName,
                kind: .ssh(makeEndpoint())
            )
        }
    }

    /// Port 22 stands for "not typed": the connection then takes the
    /// ssh_config port (see `ResolvedSSHEndpoint`).
    private func makeEndpoint() -> SSHEndpoint {
        let auth: SSHAuthMode
        var identityFile: String?
        switch authChoice {
        case .automatic:
            auth = .automatic
        case .keyFile:
            auth = .keyFile(keyFilePath)
            identityFile = keyFilePath
        case .password:
            auth = .password
        }
        return SSHEndpoint(
            host: trimmedHost,
            port: portInput.value ?? 22,
            username: user.trimmingCharacters(in: .whitespacesAndNewlines),
            identityFile: identityFile,
            auth: auth
        )
    }

    private func testConnection() {
        guard canAdd else { return }
        connectionTest.start(makeHost())
    }

    private func add() {
        guard canAdd else { return }
        connectionTest.reset()
        let dockerHost = makeHost()
        // Stash the password into the Keychain so the connection can find it.
        if hostType == .ssh, authChoice == .password, !password.isEmpty {
            KeychainStore.set(
                password,
                account: KeychainStore.sshPasswordAccount(hostID: dockerHost.id)
            )
        }
        model.addHost(dockerHost)
        dismiss()
    }

    /// Fills the form from a picked ~/.ssh/config alias. Port and user stay
    /// empty: the summary shows what ssh_config gives them.
    private func applyConfigHost(_ alias: String) {
        name = alias
        host = alias
        port = ""
        user = ""
        authChoice = .automatic
    }

    /// Fills the SSH fields from a saved Docker context's `ssh://` endpoint.
    private func applyDockerContext(_ contextName: String) {
        guard let entry = dockerContexts.first(where: { $0.name == contextName }),
              case .ssh(let h, let p, let u) = DockerContextStore.endpoint(for: entry.host)
        else { return }
        name = contextName
        host = h
        port = p == 22 ? "" : String(p)
        user = u
        authChoice = .automatic
    }

    /// Debounced ssh_config resolution for the summary under the fields.
    private func scheduleResolve() {
        resolveTask?.cancel()
        guard hostType == .ssh, !trimmedHost.isEmpty, hostMessage == nil else {
            summary = nil
            return
        }
        let endpoint = makeEndpoint()
        resolveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let resolved = SSHConnectionSummary(endpoint: endpoint)
            guard !Task.isCancelled else { return }
            summary = resolved
        }
    }
}

/// The values an SSH host resolves to: destination, key and ProxyJump hops.
private struct SSHSummaryView: View {
    let summary: SSHConnectionSummary
    let authChoice: AuthChoice

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Text("Connects to").foregroundStyle(.secondary)
                Text(verbatim: summary.destination).monospaced()
            }
            GridRow {
                Text("Key").foregroundStyle(.secondary)
                keyText
            }
            if !summary.jumps.isEmpty {
                GridRow {
                    Text("Through").foregroundStyle(.secondary)
                    Text(verbatim: summary.jumps.joined(separator: " → ")).monospaced()
                }
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var keyText: some View {
        if authChoice == .password {
            Text("Password")
        } else if let key = summary.key {
            Text(verbatim: key).monospaced()
        } else {
            Text("Default keys (~/.ssh/id_*)")
        }
    }
}

/// The inline result of "Test Connection".
private struct ConnectionTestStatus: View {
    let test: ConnectionTest
    let engineName: String

    var body: some View {
        switch test.state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Testing the connection…").foregroundStyle(.secondary)
                Button("Stop") { test.reset() }
                    .controlSize(.small)
            }
            .font(.callout)
        case .succeeded(let version):
            Label {
                Text("Connected: \(engineName) \(version.version)")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        case .failed(let message):
            Label {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .font(.callout)
        }
    }
}

/// Host key and passphrase prompts of the session under test. A password
/// typed in the form answers the password prompt without asking again.
private struct ConnectionTestPrompts: ViewModifier {
    let test: ConnectionTest
    let password: String

    private var session: HostSession? { test.session }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: hostKeyBinding) {
                if let session, let prompt = session.pendingHostKeyPrompt {
                    HostKeySheet(session: session, prompt: prompt)
                }
            }
            .sheet(isPresented: credentialBinding) {
                if let session, let request = session.pendingCredentialRequest {
                    CredentialSheet(session: session, request: request)
                }
            }
            .onChange(of: session?.pendingCredentialRequest?.id) {
                guard let session, let request = session.pendingCredentialRequest,
                      request.kind == .password, !password.isEmpty else { return }
                session.submitCredential(password, store: false)
            }
    }

    private var hostKeyBinding: Binding<Bool> {
        Binding(
            get: { session?.pendingHostKeyPrompt != nil },
            set: { if !$0 { session?.submitHostKeyDecision(trust: false) } }
        )
    }

    private var credentialBinding: Binding<Bool> {
        Binding(
            get: {
                guard let request = session?.pendingCredentialRequest else { return false }
                return request.kind != .password || password.isEmpty
            },
            set: { if !$0 { session?.cancelCredential() } }
        )
    }
}
